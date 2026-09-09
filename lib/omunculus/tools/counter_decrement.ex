defmodule Omunculus.Tools.CounterDecrement do
  @moduledoc false
  @behaviour Omunculus.Tool

  def name, do: "counter_decrement"

  def schema do
    Omunculus.Tools.Counter.schema()
    |> Map.put("name", name())
    |> Map.put(
      "description",
      "Decrement the same counter resource by one configured unit. Every call mutates the resource and returns its new value. Does not reset prior effects; do not use for verification."
    )
  end

  def call(args, context), do: Omunculus.Tools.Counter.change(args, context, name(), -1)
end
