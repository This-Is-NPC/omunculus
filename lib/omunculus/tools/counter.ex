defmodule Omunculus.Tools.Counter do
  @moduledoc """
  Builtin `counter` tool, per spec §9.4: steps the bench counter file under
  `.omunculus/counter` in the first root and returns the new value.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(input), do: step(input, 1)

  @spec step(map, integer) :: map
  def step(%{roots: []}, _delta), do: Out.fail("no root")

  def step(%{roots: [root | _]}, delta) do
    path = Path.join([root, ".omunculus", "counter"])
    File.mkdir_p!(Path.dirname(path))
    value = current(path) + delta
    File.write!(path, Integer.to_string(value))
    Out.ok(Integer.to_string(value))
  end

  defp current(path) do
    case File.read(path) do
      {:ok, content} -> String.to_integer(String.trim(content))
      {:error, _reason} -> 0
    end
  end
end
