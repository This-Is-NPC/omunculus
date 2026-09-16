defmodule Omunculus.Path do
  @moduledoc """
  Resolves paths through existing symbolic links and compares canonical path
  boundaries.
  """

  @spec canonical(String.t()) :: {:ok, String.t()} | {:error, term}
  def canonical(path), do: canonical(Path.expand(path), 0)

  @spec within?(String.t(), String.t()) :: boolean
  def within?(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)
    path == root or String.starts_with?(path, String.trim_trailing(root, "/") <> "/")
  end

  defp canonical(_path, links) when links > 40, do: {:error, :symlink_loop}
  defp canonical(path, links), do: walk(Path.split(path), "/", links)

  defp walk([], path, _links), do: {:ok, path}

  defp walk([part | rest], parent, links) do
    path = Path.join(parent, part)

    case File.read_link(path) do
      {:ok, target} -> canonical(Path.join([Path.expand(target, parent) | rest]), links + 1)
      {:error, reason} when reason in [:einval, :enoent] -> walk(rest, path, links)
      {:error, reason} -> {:error, reason}
    end
  end
end
