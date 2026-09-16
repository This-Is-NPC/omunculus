defmodule Omunculus.Tools.Directory do
  @moduledoc """
  Builtin `directory` tool, per spec §9.4: lists every root of the run,
  each followed by its top-level entries indented, directories suffixed
  with `/`.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{roots: roots}) do
    Out.ok(Enum.map_join(roots, "\n\n", &root_block/1))
  end

  defp root_block(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(&("  " <> entry(root, &1)))
        |> then(&Enum.join([root | &1], "\n"))

      {:error, _reason} ->
        root
    end
  end

  defp entry(root, name) do
    if File.dir?(Path.join(root, name)), do: name <> "/", else: name
  end
end
