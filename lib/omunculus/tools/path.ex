defmodule Omunculus.Tools.Path do
  @moduledoc "Checks lexical and symlink-resolved paths against roots and the store's path permissions."

  alias Omunculus.Execution.Policy
  alias Omunculus.Path, as: FilesystemPath

  def permissions(input), do: input |> Map.get(:view, %{}) |> Map.get("paths", %{})

  def resolve(roots, path, permissions \\ %{})
  def resolve([], _path, _permissions), do: {:error, "no roots"}

  def resolve(roots, path, permissions) do
    absolute = Path.expand(path, hd(roots))

    with {:ok, real} <- FilesystemPath.canonical(absolute),
         true <- permitted?(absolute, roots, permissions),
         true <- permitted?(real, canonical_paths(roots), canonical_permissions(permissions)) do
      {:ok, real}
    else
      _ -> {:error, "path outside roots: #{path}"}
    end
  end

  @spec resolve([String.t()], String.t(), map, Policy.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve(roots, path, permissions, %Policy{} = policy) do
    with {:ok, real} <- resolve(roots, path, permissions),
         true <- Policy.readable?(policy, real) do
      {:ok, real}
    else
      _ -> {:error, "path outside roots: #{path}"}
    end
  end

  defp permitted?(path, roots, permissions) do
    allowed = Enum.any?(Map.get(permissions, "allowed", []), &FilesystemPath.within?(&1, path))
    denied = Enum.any?(Map.get(permissions, "denied", []), &FilesystemPath.within?(&1, path))

    restricted =
      Enum.any?(Map.get(permissions, "restricted", []), &FilesystemPath.within?(&1, path))

    not denied and
      (allowed or (not restricted and Enum.any?(roots, &FilesystemPath.within?(&1, path))))
  end

  defp canonical_permissions(permissions),
    do: Map.new(permissions, fn {key, paths} -> {key, canonical_paths(paths)} end)

  defp canonical_paths(paths) do
    Enum.flat_map(paths, fn path ->
      case FilesystemPath.canonical(Path.expand(path)) do
        {:ok, real} -> [real]
        _ -> []
      end
    end)
  end
end
