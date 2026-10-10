defmodule Omunculus.Changes do
  @moduledoc """
  The files a call changed in its workspace, kept as git trees in the
  bare repository `[store] changes` names, apart from any repository the
  workspace has. `snapshot/3` writes the workspace's tree, through an
  index of its own for each root, so git hashes only what changed since
  the last snapshot; it honours the workspace's `.gitignore` and leaves
  out the paths given, and what starts with them (the store and its
  sidecar files, when they lie inside the root). `files/3`
  lists what differs between two trees, and `patch/4` is their unified
  diff; `object/3`, `hash/2` and `content/2` read a file of a tree and
  of the workspace, to put one back. git runs on the harness side, outside the sandbox, with no user or
  system configuration; snapshots of one root take turns.
  """

  @type file :: %{String.t() => String.t() | non_neg_integer | nil}

  @spec snapshot(String.t(), String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term}
  def snapshot(dir, root, excluded) do
    :global.trans({{__MODULE__, root}, self()}, fn ->
      with :ok <- ensure(dir),
           {:ok, _added} <-
             git(dir, root, ["add", "--all", "--", "." | exclusions(root, excluded)]),
           {:ok, tree} <- git(dir, root, ["write-tree"]) do
        {:ok, String.trim(tree)}
      end
    end)
  end

  @doc "What differs between two trees: each file's `path`, `op` (A, M, D) and lines `added` and `deleted` (nil for a binary file)."
  @spec files(String.t(), String.t(), String.t()) :: {:ok, [file]} | {:error, term}
  def files(_dir, tree, tree), do: {:ok, []}

  def files(dir, before, after_) do
    with {:ok, status} <-
           git(dir, nil, ["diff-tree", "-r", "-z", "--name-status", before, after_]),
         {:ok, counts} <- git(dir, nil, ["diff-tree", "-r", "-z", "--numstat", before, after_]) do
      counts = counts(counts)

      {:ok,
       status
       |> fields()
       |> Enum.chunk_every(2)
       |> Enum.map(fn [op, path] ->
         {added, deleted} = Map.get(counts, path, {nil, nil})
         %{"path" => path, "op" => op, "added" => added, "deleted" => deleted}
       end)}
    end
  end

  @doc "The unified diff between two trees, of the `paths` given or of all."
  @spec patch(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, term}
  def patch(dir, before, after_, paths \\ []),
    do: git(dir, nil, ["diff-tree", "-p", "--no-color", before, after_, "--" | paths])

  @doc "The object of `path` in `tree`, or nil when the tree has no such file."
  @spec object(String.t(), String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term}
  def object(dir, tree, path) do
    case git(dir, nil, ["ls-tree", "-z", tree, "--", path]) do
      {:ok, ""} -> {:ok, nil}
      {:ok, entry} -> {:ok, entry |> String.split([" ", "\t"]) |> Enum.at(2)}
      error -> error
    end
  end

  @doc "The object the file at `absolute` would be, or nil when there is none."
  @spec hash(String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term}
  def hash(dir, absolute) do
    if File.regular?(absolute),
      do:
        with(
          {:ok, sha} <- git(dir, nil, ["hash-object", "--no-filters", absolute]),
          do: {:ok, String.trim(sha)}
        ),
      else: {:ok, nil}
  end

  @doc "The content of an object."
  @spec content(String.t(), String.t()) :: {:ok, binary} | {:error, term}
  def content(dir, object), do: git(dir, nil, ["cat-file", "blob", object])

  defp ensure(dir) do
    if File.dir?(dir) do
      :ok
    else
      File.mkdir_p!(Path.dirname(dir))

      case System.cmd("git", ["init", "--bare", "--quiet", dir],
             env: env(),
             stderr_to_stdout: true
           ) do
        {_said, 0} -> :ok
        {said, _status} -> {:error, {:changes, String.trim(said)}}
      end
    end
  end

  # A path left out takes what starts with it along: the store's journal,
  # lock and socket beside it, or everything below a directory.
  defp exclusions(root, excluded) do
    for path <- excluded,
        relative = Path.relative_to(path, root),
        relative != path and relative != ".",
        pattern <- [relative <> "*", relative <> "*/**"],
        do: ":(exclude,glob)" <> pattern
  end

  defp git(dir, root, args) do
    env =
      [{"GIT_DIR", dir}] ++
        if(root,
          do: [
            {"GIT_WORK_TREE", root},
            {"GIT_INDEX_FILE", Path.join(dir, "index-" <> index_name(root))}
          ],
          else: []
        ) ++ env()

    case System.cmd("git", args, env: env, cd: root || dir, stderr_to_stdout: true) do
      {said, 0} -> {:ok, said}
      {said, _status} -> {:error, {:changes, String.trim(said)}}
    end
  end

  defp env,
    do: [
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_OPTIONAL_LOCKS", "0"}
    ]

  defp index_name(root), do: :crypto.hash(:sha256, root) |> Base.encode16(case: :lower)

  defp fields(output), do: output |> String.split(<<0>>, trim: true)

  defp counts(output) do
    output
    |> fields()
    |> Map.new(fn line ->
      [added, deleted, path] = String.split(line, "\t", parts: 3)
      {path, {count(added), count(deleted)}}
    end)
  end

  defp count("-"), do: nil
  defp count(n), do: String.to_integer(n)
end
