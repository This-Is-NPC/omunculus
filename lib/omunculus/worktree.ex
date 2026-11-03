defmodule Omunculus.Worktree do
  @moduledoc """
  The git worktree a work of a workflow with `isolate = "worktree"` works
  in: `<workspace root>/.omunculus-worktrees/<work id>`, on the branch
  `work/<work id>`. `prepare/4` creates it before the work's run, from the
  parent work's branch when the parent is isolated too, else from the
  workspace's `HEAD`; the workspace must be the root of a git repository
  with a commit. The folder is listed in the repository's `info/exclude`.
  `remove/1` commits what the work left and removes the worktree, keeping
  the branch. `merge/2` merges a work's branch into the checkout at a
  root; on a conflict it aborts and names the paths. git runs through
  `Omunculus.Git`.
  """

  alias Omunculus.{Config, Git, Store}
  alias Omunculus.Path, as: FilesystemPath

  @dir ".omunculus-worktrees"

  @doc "Whether `work` goes through a workflow that isolates its works."
  @spec isolated?(Config.t(), map | nil) :: boolean
  def isolated?(%Config{isolated: names}, %{workflow: workflow}) when is_binary(workflow),
    do: workflow in names

  def isolated?(_config, _work), do: false

  @doc "The folder that holds the worktrees of the workspace at `root`."
  @spec dir(String.t()) :: String.t()
  def dir(root), do: Path.join(root, @dir)

  @doc "The worktree of the work `id` in the workspace at `root`."
  @spec path(String.t(), String.t()) :: String.t()
  def path(root, id), do: Path.join([root, @dir, id])

  @spec branch(String.t()) :: String.t()
  def branch(id), do: "work/" <> id

  @doc "Creates the worktree of `work` at `path` when its workflow isolates and it is not there."
  @spec prepare(Store.Connection.t(), Config.t(), map | nil, String.t()) ::
          :ok | {:error, {:worktree, String.t()}}
  def prepare(conn, config, work, path) do
    if isolated?(config, work) and not File.dir?(path) do
      base = base_of(path)

      :global.trans({{__MODULE__, base}, self()}, fn ->
        with :ok <- repository(base),
             :ok <- exclude(base),
             {:ok, start} <- start(conn, config, work),
             do: add(base, path, work.id, start)
      end)
    else
      :ok
    end
  end

  @doc "Commits what the work left in the worktree at `path` and removes it; its branch stays."
  @spec remove(String.t()) :: :ok | {:error, {:worktree, String.t()}}
  def remove(path) do
    if File.dir?(path) do
      with {:ok, status} <- git(["status", "--porcelain"], path),
           :ok <- commit(status, path, Path.basename(path)),
           {:ok, _said} <- git(["worktree", "remove", "--force", path], base_of(path)),
           do: :ok
    else
      :ok
    end
  end

  @doc """
  Merges the branch of the work `id` into the checkout at `root`. A
  conflict is aborted and returned with its paths.
  """
  @spec merge(String.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, [String.t()]} | {:error, String.t()}
  def merge(root, id) do
    args = [
      "-c",
      "commit.gpgsign=false",
      "merge",
      "--no-ff",
      "--no-verify",
      "-m",
      "merge work " <> id,
      branch(id)
    ]

    case Git.run(args, root) do
      {:ok, said} -> {:ok, String.trim(said)}
      {:error, _status, said} -> failed_merge(root, said)
    end
  end

  defp failed_merge(root, said) do
    with {:ok, unmerged} <- Git.run(["diff", "--name-only", "--diff-filter=U"], root),
         [_ | _] = paths <- String.split(unmerged, "\n", trim: true) do
      _ = Git.run(["merge", "--abort"], root)
      {:conflict, paths}
    else
      _no_conflict -> {:error, String.trim(said)}
    end
  end

  defp base_of(path), do: path |> Path.dirname() |> Path.dirname()

  defp repository(base) do
    with true <- File.dir?(base),
         {:ok, top} <- Git.run(["rev-parse", "--show-toplevel"], base),
         {:ok, canonical} <- FilesystemPath.canonical(base),
         true <- String.trim(top) == canonical do
      :ok
    else
      _ ->
        {:error,
         {:worktree, "isolate = \"worktree\" needs #{base} to be the root of a git repository"}}
    end
  end

  # Keeps the worktrees out of the repository's status and commits.
  defp exclude(base) do
    with {:ok, said} <- git(["rev-parse", "--git-path", "info/exclude"], base) do
      file = Path.expand(String.trim(said), base)
      line = @dir <> "/"
      lines = if File.exists?(file), do: file |> File.read!() |> String.split("\n"), else: []

      if line in lines do
        :ok
      else
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, line <> "\n", [:append])
      end
    end
  end

  defp start(conn, config, %{parent_id: parent_id}) when is_binary(parent_id) do
    with {:ok, parent} <- Store.view(conn, "work", parent_id) do
      {:ok, if(isolated?(config, parent), do: branch(parent_id), else: "HEAD")}
    end
  end

  defp start(_conn, _config, _work), do: {:ok, "HEAD"}

  defp add(base, path, id, start) do
    branch = branch(id)

    with {:ok, _said} <- git(["worktree", "prune"], base) do
      args =
        case Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch], base) do
          {:ok, _said} -> ["worktree", "add", path, branch]
          {:error, _status, _said} -> ["worktree", "add", "-b", branch, path, start]
        end

      with {:ok, _said} <- git(args, base), do: :ok
    end
  end

  defp commit("", _path, _id), do: :ok

  defp commit(_status, path, id) do
    commit = [
      "-c",
      "commit.gpgsign=false",
      "commit",
      "--quiet",
      "--no-verify",
      "-m",
      "work " <> id
    ]

    with {:ok, _said} <- git(["add", "--all"], path),
         {:ok, _said} <- git(commit, path),
         do: :ok
  end

  defp git(args, cd) do
    case Git.run(args, cd) do
      {:ok, said} -> {:ok, said}
      {:error, _status, said} -> {:error, {:worktree, String.trim(said)}}
    end
  end
end
