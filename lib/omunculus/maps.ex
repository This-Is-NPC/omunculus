defmodule Omunculus.Maps do
  @moduledoc """
  Map helpers shared by the config loader, the model adapters and the server.
  """

  @doc "Puts `value` under `key`, leaving `map` as it is when `value` is nil."
  @spec maybe_put(map, term, term) :: map
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)
end
