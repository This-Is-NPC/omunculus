defmodule Omunculus.Tools.Read do
  @moduledoc """
  Builtin `read` tool: reads a file's contents from under
  the run's roots. With `offset` (the first line, from 1) or `limit` (how
  many lines), it reads those lines and a last line says which lines of
  how many it shows. An image or a PDF is shown to the model
  (`Omunculus.Media`); another file that is not text is refused with its
  size.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Media
  alias Omunculus.Tools.{Args, Out}

  @spec run(map, Policy.t()) :: map
  def run(%{args: args, roots: roots} = input, %Policy{} = policy) do
    permissions = Omunculus.Tools.Path.permissions(input)

    with nil <- Args.missing(args, ~w(path)),
         {:ok, offset} <- Args.count(args, "offset"),
         {:ok, limit} <- Args.count(args, "limit") do
      read(roots, args["path"], {offset, limit}, permissions, policy)
    else
      {:error, message} -> Out.fail(message)
      message -> Out.fail(message)
    end
  end

  defp read(roots, path, range, permissions, policy) do
    with {:ok, absolute} <- Omunculus.Tools.Path.resolve(roots, path, permissions, policy),
         {:ok, content} <- File.read(absolute) do
      Media.shown(path, content, %{"path" => path}) || text_lines(content, path, range)
    else
      {:error, reason} when is_atom(reason) -> Out.fail("no such file: #{path}")
      {:error, message} -> Out.fail(message)
    end
  end

  defp text_lines(content, path, range) do
    if String.valid?(content),
      do: lines(content, range),
      else: Out.fail(Out.not_text(path, byte_size(content)))
  end

  defp lines(content, {nil, nil}), do: Out.ok(content)

  defp lines(content, {offset, limit}) do
    lines = Regex.split(~r/(?<=\n)/, content, trim: true)
    total = length(lines)
    first = offset || 1

    if first > total do
      Out.fail("offset #{first} is past the last line, #{total}")
    else
      shown = Enum.slice(lines, first - 1, limit || total)
      last = first + length(shown) - 1
      text = Enum.join(shown)
      text = if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
      Out.ok(text <> Out.lines_shown(first, last, total))
    end
  end
end
