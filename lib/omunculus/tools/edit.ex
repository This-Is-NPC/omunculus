defmodule Omunculus.Tools.Edit do
  @moduledoc """
  Builtin `edit` tool: applies `edits`, each an exact `old`
  span and its `new` text, to the file at `path` under the run's roots.
  Every `old` is found in the file as it was before the call, once, and
  apart from the others; one that is missing, repeated or overlapping
  another refuses them all. Line endings and a byte order mark are kept:
  a CRLF file is matched and edited as LF and written back as CRLF. The
  file is written whole or not at all. When this run read, edited or
  wrote the file before (its `run` view) and the file changed on disk
  since, the edit is refused until it is read again.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.{Args, Out}

  @bom "﻿"

  @spec run(map, Policy.t()) :: map
  def run(%{args: args, roots: roots} = input, %Policy{} = policy) do
    permissions = Omunculus.Tools.Path.permissions(input)

    with nil <- Args.missing(args, ["path"]),
         {:ok, edits} <- edits(args["edits"]),
         {:ok, absolute} <-
           Omunculus.Tools.Path.resolve(roots, args["path"], permissions, policy),
         :ok <- Omunculus.Tools.Path.writable(policy, absolute, args["path"]),
         {:ok, content} <- read(absolute, args["path"]),
         :ok <- fresh(absolute, args["path"], roots, Map.get(input.view, "run", [])),
         {:ok, edited} <- apply_edits(content, edits),
         :ok <- Omunculus.Tools.Path.write_atomic(absolute, edited) do
      Out.ok()
    else
      {:error, message} -> Out.fail(message)
      message when is_binary(message) -> Out.fail(message)
    end
  end

  defp edits([_ | _] = edits) do
    if Enum.all?(
         edits,
         &match?(
           %{"old" => old, "new" => new} when is_binary(old) and old != "" and is_binary(new),
           &1
         )
       ),
       do: {:ok, Enum.map(edits, &{&1["old"], &1["new"]})},
       else: {:error, "each edit needs a non-empty old and a new"}
  end

  defp edits(_edits), do: {:error, "edits required: a list of {old, new}"}

  defp read(absolute, path) do
    case File.read(absolute) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, "no such file: #{path}"}
    end
  end

  # The file changed since this run last saw it: by a command, another run
  # or a person.
  defp fresh(absolute, path, [root | _], events) do
    seen =
      for %{type: "tool", body: body, at: at} <- events,
          %{"name" => name, "ok" => true, "args" => %{"path" => seen}} <- [Jason.decode!(body)],
          name in ~w(read edit write),
          Path.expand(seen, root) == absolute,
          do: at

    with [_ | _] <- seen,
         {:ok, at, _offset} <- DateTime.from_iso8601(List.last(seen)),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(absolute, time: :posix),
         true <- mtime > DateTime.to_unix(at) do
      {:error, "#{path} changed since you last read it: read it again, then edit"}
    else
      _unchanged -> :ok
    end
  end

  defp apply_edits(content, edits) do
    {bom, body} = split_bom(content)
    crlf? = String.contains?(body, "\r\n")
    text = if crlf?, do: lf(body), else: body
    edits = if crlf?, do: Enum.map(edits, fn {old, new} -> {lf(old), lf(new)} end), else: edits

    with {:ok, spans} <- spans(text, edits),
         :ok <- apart(spans) do
      edited = replace(text, spans)
      {:ok, bom <> if(crlf?, do: String.replace(edited, "\n", "\r\n"), else: edited)}
    end
  end

  defp split_bom(@bom <> rest), do: {@bom, rest}
  defp split_bom(content), do: {"", content}

  defp lf(text), do: String.replace(text, "\r\n", "\n")

  # Where each old span lies in the file as it was: {start, length, new, index}.
  defp spans(text, edits) do
    edits
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {{old, new}, index}, {:ok, acc} ->
      case :binary.matches(text, old) do
        _matches when old == new ->
          {:halt, {:error, "edits[#{index}]: new is the same as old"}}

        [] ->
          {:halt, {:error, "edits[#{index}]: old text not found"}}

        [{start, length}] ->
          {:cont, {:ok, acc ++ [{start, length, new, index}]}}

        matches ->
          {:halt, {:error, "edits[#{index}]: old text is ambiguous: #{length(matches)} matches"}}
      end
    end)
  end

  defp apart(spans) do
    spans
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [{start, length, _, _}, {next, _, _, _}] -> start + length > next end)
    |> case do
      nil ->
        :ok

      [{_, _, _, a}, {_, _, _, b}] ->
        {:error, "edits[#{min(a, b)}] and edits[#{max(a, b)}] overlap"}
    end
  end

  defp replace(text, spans) do
    {parts, rest_at} =
      spans
      |> Enum.sort()
      |> Enum.reduce({[], 0}, fn {start, length, new, _index}, {parts, at} ->
        {[new, binary_part(text, at, start - at) | parts], start + length}
      end)

    [binary_part(text, rest_at, byte_size(text) - rest_at) | parts]
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
