defmodule Omunculus.Sandbox do
  @moduledoc false

  def resolve(root, path) when is_binary(root) and is_binary(path) do
    root = Path.expand(root)
    abs = Path.expand(path, root)

    if inside?(root, abs) do
      follow(abs, root)
    else
      {:error, :path_escape}
    end
  end

  def inside?(root, path) do
    root = root |> Path.absname() |> String.trim_trailing("/")
    path = Path.absname(path)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp follow(path, root) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} ->
            target =
              if Path.type(target) == :absolute,
                do: Path.expand(target),
                else: Path.expand(target, Path.dirname(path))

            if inside?(root, target), do: follow(target, root), else: {:error, :path_escape}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _} ->
        {:ok, Path.expand(path)}

      {:error, :enoent} ->
        parent = Path.dirname(path)

        case follow(parent, root) do
          {:ok, real_parent} ->
            if inside?(root, real_parent),
              do: {:ok, Path.join(real_parent, Path.basename(path))},
              else: {:error, :path_escape}

          {:error, :enoent} ->
            if inside?(root, parent), do: {:ok, path}, else: {:error, :path_escape}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
