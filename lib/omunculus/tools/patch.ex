defmodule Omunculus.Tools.Patch do
  @moduledoc """
  Builtin `patch` tool: applies a patch to one or more files under the
  run's roots, all or none. The format is `*** Begin Patch` and `*** End
  Patch` around sections: `*** Add File: path` (every line starts with
  `+`; the file must not exist), `*** Delete File: path`, and `*** Update
  File: path` with hunks separated by `@@` lines, each line a context
  line (a space), a removed line (`-`) or an added one (`+`). A hunk is
  matched as the exact lines it removes and keeps, through the matching
  of `edit` (once in the file, apart from the other hunks, line endings
  kept). A file is written only when every section applies; a failed
  write puts back the files already written. The files written are then
  formatted ([`Format`](`Omunculus.Tools.Format`)).
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.{Args, Edit, Format, Out}

  @headers ["*** Add File: ", "*** Update File: ", "*** Delete File: "]

  @spec run(map, Policy.t()) :: map
  def run(%{args: args, roots: roots} = input, %Policy{} = policy) do
    permissions = Omunculus.Tools.Path.permissions(input)
    events = Map.get(input.view, "run", [])
    format = Map.get(input.view, "format", %{})

    with {:ok, text} <- Args.fetch(args, "patch"),
         {:ok, sections} <- parse(text),
         {:ok, plan} <- plan(sections, roots, permissions, policy, events),
         :ok <- commit(plan) do
      written = for %{after: content, absolute: absolute} <- plan, content, do: absolute
      done = Enum.map_join(plan, "\n", &"#{&1.verb} #{&1.path}")

      Out.ok(
        Enum.join(Enum.reject([done, Format.run(format, written, policy)], &(&1 == "")), "\n")
      )
    else
      {:error, message} -> Out.fail(message)
    end
  end

  defp parse(text) do
    lines = text |> String.replace("\r\n", "\n") |> String.trim() |> String.split("\n")

    with ["*** Begin Patch" | rest] <- lines,
         "*** End Patch" <- List.last(rest) do
      rest |> Enum.drop(-1) |> sections([])
    else
      _ -> {:error, "a patch starts with *** Begin Patch and ends with *** End Patch"}
    end
  end

  defp sections([], []), do: {:error, "the patch has no file section"}
  defp sections([], acc), do: {:ok, Enum.reverse(acc)}

  defp sections([header | rest], acc) do
    {body, rest} = Enum.split_while(rest, &(not String.starts_with?(&1, @headers)))

    with {:ok, section} <- section(header, body), do: sections(rest, [section | acc])
  end

  defp section("*** Add File: " <> path, body) do
    if Enum.all?(body, &String.starts_with?(&1, "+")),
      do: {:ok, {:add, path, Enum.map_join(body, &(String.slice(&1, 1..-1//1) <> "\n"))}},
      else: {:error, "#{path}: every line of an added file starts with +"}
  end

  defp section("*** Delete File: " <> path, []), do: {:ok, {:delete, path}}

  defp section("*** Delete File: " <> path, _body),
    do: {:error, "#{path}: a deleted file has no lines"}

  defp section("*** Update File: " <> path, body) do
    with {:ok, hunks} <- hunks(body), do: {:ok, {:update, path, hunks}}
  end

  defp section(line, _body), do: {:error, "unexpected line before a file section: #{line}"}

  defp hunks(body) do
    groups =
      body
      |> Enum.chunk_while(
        [],
        fn line, acc ->
          if String.starts_with?(line, "@@"),
            do: {:cont, Enum.reverse(acc), []},
            else: {:cont, [line | acc]}
        end,
        &{:cont, Enum.reverse(&1), []}
      )
      |> Enum.reject(&(&1 == []))

    groups
    |> Enum.reduce_while({:ok, []}, fn group, {:ok, acc} ->
      case hunk(group) do
        {:ok, pair} -> {:cont, {:ok, acc ++ [pair]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "an updated file needs at least one hunk"}
      result -> result
    end
  end

  # A hunk as the {old, new} lines of `edit`, each line ending in a newline.
  defp hunk(lines) do
    with {:ok, parsed} <- classify(lines) do
      old = for {kind, text} <- parsed, kind in [:keep, :remove], do: text
      new = for {kind, text} <- parsed, kind in [:keep, :add], do: text

      if old == [],
        do: {:error, "a hunk needs a context or removed line to find its place"},
        else: {:ok, {text(old), text(new)}}
    end
  end

  defp text(lines), do: Enum.map_join(lines, &(&1 <> "\n"))

  defp classify(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case line do
        " " <> text -> {:cont, {:ok, acc ++ [{:keep, text}]}}
        "-" <> text -> {:cont, {:ok, acc ++ [{:remove, text}]}}
        "+" <> text -> {:cont, {:ok, acc ++ [{:add, text}]}}
        "" -> {:cont, {:ok, acc ++ [{:keep, ""}]}}
        other -> {:halt, {:error, "a hunk line starts with a space, - or +: #{other}"}}
      end
    end)
  end

  # Every file's content before and after, checked against the roots and
  # the policy, before anything is written.
  defp plan(sections, roots, permissions, policy, events) do
    sections
    |> Enum.reduce_while({:ok, []}, fn section, {:ok, acc} ->
      with {:ok, entry} <- entry(section, roots, permissions, policy, events),
           false <- Enum.any?(acc, &(&1.absolute == entry.absolute)) do
        {:cont, {:ok, acc ++ [entry]}}
      else
        true -> {:halt, {:error, "#{elem(section, 1)}: the patch names this file twice"}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp entry({:delete, path}, roots, permissions, policy, events) do
    with {:ok, absolute} <- locate(path, roots, permissions, policy),
         {:ok, before} <- read(absolute, path),
         :ok <- Edit.fresh(absolute, path, roots, events) do
      {:ok, %{absolute: absolute, path: path, before: before, after: nil, verb: "deleted"}}
    end
  end

  defp entry({:add, path, content}, roots, permissions, policy, _events) do
    with {:ok, absolute} <- locate(path, roots, permissions, policy) do
      if File.exists?(absolute),
        do: {:error, "#{path}: file exists; update it instead"},
        else: {:ok, %{absolute: absolute, path: path, before: nil, after: content, verb: "added"}}
    end
  end

  defp entry({:update, path, hunks}, roots, permissions, policy, events) do
    with {:ok, absolute} <- locate(path, roots, permissions, policy),
         {:ok, before} <- read(absolute, path),
         :ok <- Edit.fresh(absolute, path, roots, events),
         {:ok, edited} <- apply_hunks(before, hunks, path) do
      {:ok, %{absolute: absolute, path: path, before: before, after: edited, verb: "updated"}}
    end
  end

  defp apply_hunks(content, hunks, path) do
    case Edit.apply_edits(content, hunks, "hunk") do
      {:error, message} -> {:error, "#{path}: #{message}"}
      ok -> ok
    end
  end

  defp locate(path, roots, permissions, policy) do
    with {:ok, absolute} <- Omunculus.Tools.Path.resolve(roots, path, permissions, policy),
         :ok <- Omunculus.Tools.Path.writable(policy, absolute, path) do
      {:ok, absolute}
    end
  end

  defp read(absolute, path) do
    case File.read(absolute) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, "no such file: #{path}"}
    end
  end

  defp commit(plan), do: commit(plan, [])

  defp commit([], _done), do: :ok

  defp commit([entry | rest], done) do
    case put(entry.absolute, entry.after) do
      :ok ->
        commit(rest, [entry | done])

      {:error, _message} = error ->
        Enum.each(done, &put(&1.absolute, &1.before))
        error
    end
  end

  defp put(absolute, nil) do
    case File.rm(absolute) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "could not remove #{Path.basename(absolute)}: #{:file.format_error(reason)}"}
    end
  end

  defp put(absolute, content), do: Omunculus.Tools.Path.write_atomic(absolute, content)
end
