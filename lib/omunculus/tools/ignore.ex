defmodule Omunculus.Tools.Ignore do
  @moduledoc """
  Leaves out, of the paths a search found under `dir`, a `.git` directory
  and, when `dir` lies in a git repository, what its `.gitignore` files
  ignore: a file is kept when git lists it, a directory when it holds one
  git lists.
  """

  @spec reject([String.t()], String.t()) :: [String.t()]
  def reject(paths, dir) do
    paths = Enum.reject(paths, &(".git" in Path.split(Path.relative_to(&1, dir))))

    case Omunculus.Git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], dir) do
      {:ok, listed} ->
        kept =
          for file <- String.split(listed, <<0>>, trim: true),
              path <- ancestors(Path.join(dir, file), dir),
              into: MapSet.new(),
              do: path

        Enum.filter(paths, &MapSet.member?(kept, &1))

      {:error, _status, _said} ->
        paths
    end
  end

  defp ancestors(path, dir) when path in [dir, "/"], do: []
  defp ancestors(path, dir), do: [path | ancestors(Path.dirname(path), dir)]
end
