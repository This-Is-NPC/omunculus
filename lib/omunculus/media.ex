defmodule Omunculus.Media do
  @moduledoc """
  The images and PDFs a tool shows the model. A tool's `out` may carry
  `media`, a list of parts: a `media_type`, an optional `name`, and where
  the bytes are: `data` (base64), the `sha256` of a kept attachment, or a
  `path` in the workspace. The one shape every model adapter maps to its
  provider.

  `keep/2` runs once, in the harness: it checks each part against the
  `[policy] media_bytes` limit and the run's paths, and keeps its bytes in
  `Omunculus.Attachments`, so the part becomes the attachment's
  `%{"name", "media_type", "bytes", "sha256"}`. That reference is what the
  call's event records; the bytes are kept once, under their SHA-256.
  `result/3` gives the model's call the output text and the kept files;
  `render/2` reads and base64-encodes them for an adapter, saying in words
  what the model cannot take.
  """

  alias Omunculus.{Attachments, Tools}
  alias Omunculus.Tools.Out

  @supported ~w(image/png image/jpeg image/gif image/webp application/pdf)

  @typedoc "A call's result for the model: its text, or its text and the files to show."
  @type result :: String.t() | %{text: String.t(), media: [map]}

  @doc "The media types the adapters can put on a wire."
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc "The media type `content` is, by its first bytes, among the supported ones; nil otherwise."
  @spec type(binary) :: String.t() | nil
  def type(<<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>), do: "image/png"
  def type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def type(<<"GIF8", _::binary>>), do: "image/gif"
  def type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  def type(<<"%PDF-", _::binary>>), do: "application/pdf"
  def type(_content), do: nil

  @doc """
  The `out` of a tool that shows `content`, named `name` and kept at
  `source` (`%{"path" => ..}` or `%{"sha256" => ..}`), or nil when it is
  not an image or a PDF.
  """
  @spec shown(String.t(), binary, map) :: map | nil
  def shown(name, content, source) do
    if type = type(content) do
      part = Map.merge(source, %{"media_type" => type, "name" => Path.basename(name)})
      Map.put(Out.ok(Out.media_shown(name, type, byte_size(content))), "media", [part])
    end
  end

  @doc """
  Keeps the media of `out`, as `%{store:, limit:, roots:, permissions:,
  policy:}` allows. What cannot be kept is left out of `out.media` and
  named, with why, in `out.output`.
  """
  @spec keep(map, map) :: map
  def keep(%{media: []} = out, _ctx), do: out

  def keep(%{media: parts} = out, ctx) do
    {refs, notes} =
      Enum.reduce(parts, {[], []}, fn part, {refs, notes} ->
        case keep_one(part, ctx) do
          {:ok, ref} -> {refs ++ [ref], notes}
          {:error, name, why} -> {refs, notes ++ [Out.media_refused(name, why)]}
        end
      end)

    %{out | media: refs, output: join(out.output, notes)}
  end

  defp keep_one(part, ctx) do
    name = part["name"] || (part["path"] && Path.basename(part["path"])) || "media"

    with {:ok, bytes} <- bytes(part, ctx),
         {:ok, ref} <- Attachments.put(ctx.store, name, part["media_type"], bytes) do
      {:ok, ref}
    else
      {:error, {:attachment, _reason} = reason} -> {:error, name, Out.failure(reason)}
      {:error, why} -> {:error, name, why}
    end
  end

  defp bytes(%{"data" => data}, ctx) do
    with {:ok, bytes} <- Attachments.decode(data),
         :ok <- within(byte_size(bytes), ctx.limit),
         do: {:ok, bytes}
  end

  defp bytes(%{"sha256" => sha256}, ctx) do
    with {:ok, file} <- Attachments.path(ctx.store, sha256),
         do: read(file, ctx.limit)
  end

  defp bytes(%{"path" => path}, ctx) do
    with {:ok, file} <- Tools.Path.resolve(ctx.roots, path, ctx.permissions, ctx.policy),
         do: read(file, ctx.limit)
  end

  defp read(file, limit) do
    with {:ok, %{size: size}} <- stat(file),
         :ok <- within(size, limit),
         {:ok, bytes} <- File.read(file) |> unreadable(),
         do: {:ok, bytes}
  end

  defp stat(file), do: file |> File.stat() |> unreadable()

  defp unreadable({:error, reason}) when is_atom(reason),
    do: {:error, Out.media_unreadable(:file.format_error(reason))}

  defp unreadable(ok), do: ok

  defp within(_size, nil), do: {:error, Out.media_limit_unset()}
  defp within(size, limit) when size <= limit, do: :ok
  defp within(size, limit), do: {:error, Out.media_too_large(size, limit)}

  @doc """
  What the model's call gets for a tool's `text` and kept `refs`: the text
  alone, or with the file of each ref. A file gone is named in the text.
  """
  @spec result(Attachments.store(), String.t(), [map]) :: result
  def result(_store, text, []), do: text

  def result(store, text, refs) do
    {parts, notes} =
      Enum.reduce(refs, {[], []}, fn ref, {parts, notes} ->
        case Attachments.path(store, ref["sha256"]) do
          {:ok, file} ->
            {parts ++ [Map.put(ref, "file", file)], notes}

          {:error, reason} ->
            {parts, notes ++ [Out.media_refused(ref["name"], Out.failure(reason))]}
        end
      end)

    case parts do
      [] -> join(text, notes)
      _parts -> %{text: join(text, notes), media: parts}
    end
  end

  @doc """
  The text and the encoded parts an adapter sends for `result`, as
  `%{"media_type", "name", "data"}`. `accepted` is the model's
  `media_types`, nil for all the supported ones; what the model cannot take
  stays out of the parts and is named in the text.
  """
  @spec render(result, [String.t()] | nil) :: {String.t(), [map]}
  def render(text, _accepted) when is_binary(text), do: {text, []}

  def render(%{text: text, media: media}, accepted) do
    taken = if accepted, do: Enum.filter(@supported, &(&1 in accepted)), else: @supported

    {parts, notes} =
      Enum.reduce(media, {[], []}, fn ref, {parts, notes} ->
        case encode(ref, taken) do
          {:ok, part} -> {parts ++ [part], notes}
          {:error, why} -> {parts, notes ++ [Out.media_refused(ref["name"], why)]}
        end
      end)

    {join(text, notes), parts}
  end

  defp encode(%{"media_type" => type} = ref, taken) do
    if type in taken do
      case File.read(ref["file"]) do
        {:ok, bytes} ->
          {:ok, %{"media_type" => type, "name" => ref["name"], "data" => Base.encode64(bytes)}}

        {:error, reason} ->
          {:error, Out.media_unreadable(:file.format_error(reason))}
      end
    else
      {:error, Out.media_not_taken(type, taken)}
    end
  end

  @doc "A data URL of an encoded part, as OpenAI's wire takes it."
  @spec data_url(map) :: String.t()
  def data_url(%{"media_type" => type, "data" => data}), do: "data:#{type};base64,#{data}"

  @doc "A call's result as text alone, for a caller that cannot show media."
  @spec text_only({:ok, result} | {:error, term}) :: {:ok, String.t()} | {:error, term}
  def text_only({:ok, %{text: text, media: media}}),
    do: {:ok, join(text, [Out.media_text_only(length(media))])}

  def text_only(other), do: other

  defp join(text, notes), do: Enum.join(Enum.reject([text | notes], &(&1 == "")), "\n")
end
