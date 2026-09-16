defmodule Omunculus.Tools.Path do
  @moduledoc """
  Authorizes a tool-given path against a run's `roots`, per spec §9.2: the
  expanded path must equal a root or live under one.
  """

  @spec resolve([String.t()], String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve([], _path), do: {:error, "no roots"}

  def resolve(roots, path) do
    absolute = Path.expand(path, hd(roots))

    if Enum.any?(roots, &within?(&1, absolute)) do
      {:ok, absolute}
    else
      {:error, "path outside roots: #{path}"}
    end
  end

  defp within?(root, absolute) do
    root = Path.expand(root)
    absolute == root or String.starts_with?(absolute, root <> "/")
  end
end
