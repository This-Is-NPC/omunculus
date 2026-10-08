defmodule Omunculus.Model.Body do
  @moduledoc """
  Merges a model's `body` table over the request body an HTTP adapter
  builds: each key of `body` replaces the request's key of the same name,
  and where both are tables they merge the same way, key by key. So a
  provider's option nobody foresaw is set in the config alone.
  """

  @spec merge(map, map) :: map
  def merge(request, body) do
    Enum.reduce(body, request, fn {key, value}, merged ->
      case Enum.find(Map.keys(merged), &(to_string(&1) == key)) do
        nil ->
          Map.put(merged, key, value)

        existing ->
          current = Map.fetch!(merged, existing)
          value = if is_map(current) and is_map(value), do: merge(current, value), else: value
          merged |> Map.delete(existing) |> Map.put(key, value)
      end
    end)
  end
end
