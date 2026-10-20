defmodule Omunculus.Attachments do
  @moduledoc """
  The files attached to conversations, kept in the directory `[store]
  attachments` names, each under its SHA-256 so a file attached twice is
  kept once and never changes. An attachment is described by
  `%{"name", "media_type", "bytes", "sha256"}`, which the event that carries
  it holds; the store has no table of them.
  """

  @type store :: %{attachments: String.t() | nil, attachment_bytes: pos_integer | nil}
  @type meta :: %{String.t() => String.t() | non_neg_integer}

  @doc "Keeps `content` as the file `name` of `media_type`, within `[store] attachment_bytes`."
  @spec put(store, String.t(), String.t(), binary) :: {:ok, meta} | {:error, {:attachment, term}}
  def put(%{attachments: nil}, _name, _media_type, _content),
    do: {:error, {:attachment, :not_configured}}

  def put(%{attachments: dir, attachment_bytes: limit}, name, media_type, content) do
    with {:ok, name} <- name(name),
         :ok <- media_type(media_type),
         :ok <- within(byte_size(content), limit) do
      sha256 = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      path = Path.join(dir, sha256)

      with :ok <- File.mkdir_p(dir),
           :ok <- write_once(path, content) do
        {:ok,
         %{
           "name" => name,
           "media_type" => media_type,
           "bytes" => byte_size(content),
           "sha256" => sha256
         }}
      else
        {:error, reason} -> {:error, {:attachment, reason}}
      end
    end
  end

  @doc "The described attachments, each checked against the file kept for it."
  @spec check(store, term) :: {:ok, [meta]} | {:error, {:attachment, term}}
  def check(%{attachments: nil}, _list), do: {:error, {:attachment, :not_configured}}

  def check(store, list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, checked} ->
      case check_one(store, item) do
        {:ok, meta} -> {:cont, {:ok, checked ++ [meta]}}
        error -> {:halt, error}
      end
    end)
  end

  def check(_store, _list), do: {:error, {:attachment, :invalid}}

  @doc "The file kept for the attachment of `sha256`."
  @spec path(store, String.t()) :: {:ok, String.t()} | {:error, {:attachment, term}}
  def path(%{attachments: nil}, _sha256), do: {:error, {:attachment, :not_configured}}

  def path(%{attachments: dir}, sha256) do
    path = Path.join(dir, sha256)

    if sha256?(sha256) and File.regular?(path),
      do: {:ok, path},
      else: {:error, {:attachment, :not_found}}
  end

  defp check_one(store, %{
         "name" => name,
         "media_type" => type,
         "bytes" => bytes,
         "sha256" => sha256
       })
       when is_integer(bytes) do
    with {:ok, name} <- name(name),
         :ok <- media_type(type),
         {:ok, path} <- path(store, sha256),
         {:ok, %{size: ^bytes}} <- File.stat(path) do
      {:ok, %{"name" => name, "media_type" => type, "bytes" => bytes, "sha256" => sha256}}
    else
      {:error, {:attachment, _reason}} = error -> error
      _other -> {:error, {:attachment, {:mismatch, sha256}}}
    end
  end

  defp check_one(_store, _item), do: {:error, {:attachment, :invalid}}

  # A name is the file's own, without a directory.
  defp name(name) when is_binary(name) do
    base = Path.basename(name)

    if base in ["", ".", ".."] or base != name or String.contains?(name, <<0>>),
      do: {:error, {:attachment, {:invalid, :name}}},
      else: {:ok, name}
  end

  defp name(_name), do: {:error, {:attachment, {:invalid, :name}}}

  defp media_type(type) when is_binary(type) do
    if Regex.match?(~r{\A[\w.+-]+/[\w.+-]+\z}, type),
      do: :ok,
      else: {:error, {:attachment, {:invalid, :media_type}}}
  end

  defp media_type(_type), do: {:error, {:attachment, {:invalid, :media_type}}}

  defp within(size, limit) when size <= limit, do: :ok
  defp within(size, limit), do: {:error, {:attachment, {:too_large, size, limit}}}

  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  # The same content is the same file: one already there is left as it is.
  defp write_once(path, content) do
    if File.regular?(path) do
      :ok
    else
      partial = path <> ".partial-" <> Integer.to_string(System.unique_integer([:positive]))

      with :ok <- File.write(partial, content) do
        File.rename(partial, path)
      end
    end
  end
end
