defmodule Omunculus.Tools.Path do
  @moduledoc "Checks lexical and symlink-resolved paths against roots and the store's path permissions."

  def permissions(input), do: input |> Map.get(:view, %{}) |> Map.get("paths", %{})

  def resolve(roots, path, permissions \\ %{})
  def resolve([], _path, _permissions), do: {:error, "no roots"}

  def resolve(roots, path, permissions) do
    absolute = Path.expand(path, hd(roots))

    with {:ok, real} <- canonical(absolute),
         true <- permitted?(absolute, roots, permissions),
         true <- permitted?(real, canonical_paths(roots), canonical_permissions(permissions)) do
      {:ok, real}
    else
      _ -> {:error, "path outside roots: #{path}"}
    end
  end

  defp permitted?(path, roots, permissions) do
    allowed = Enum.any?(Map.get(permissions, "allowed", []), &within?(&1, path))
    denied = Enum.any?(Map.get(permissions, "denied", []), &within?(&1, path))
    restricted = Enum.any?(Map.get(permissions, "restricted", []), &within?(&1, path))
    not denied and (allowed or (not restricted and Enum.any?(roots, &within?(&1, path))))
  end

  defp canonical_permissions(permissions),
    do: Map.new(permissions, fn {key, paths} -> {key, canonical_paths(paths)} end)

  defp canonical_paths(paths) do
    Enum.flat_map(paths, fn path ->
      case canonical(Path.expand(path)) do
        {:ok, real} -> [real]
        _ -> []
      end
    end)
  end

  defp within?(root, absolute) do
    root = Path.expand(root)
    absolute == root or String.starts_with?(absolute, String.trim_trailing(root, "/") <> "/")
  end

  defp canonical(path, links \\ 0)
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
