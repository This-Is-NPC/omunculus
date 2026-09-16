defmodule Omunculus.Tools.Counter do
  @moduledoc """
  Builtin `counter` tool, per spec §9.4: returns the next value derived
  from the committed counter tool calls.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(input), do: step(input, 1)

  @spec step(map, integer) :: map
  def step(%{view: %{"counter" => current}}, delta) when is_integer(current) do
    value = current + delta
    Out.ok(Integer.to_string(value))
  end

  def step(_input, _delta), do: Out.fail("counter view required")
end
