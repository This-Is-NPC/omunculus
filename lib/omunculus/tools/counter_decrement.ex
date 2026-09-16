defmodule Omunculus.Tools.CounterDecrement do
  @moduledoc """
  Builtin `counter_decrement` tool, per spec §9.4: steps the shared bench
  counter down by one.
  """

  alias Omunculus.Tools.Counter

  @spec run(map) :: map
  def run(input), do: Counter.step(input, -1)
end
