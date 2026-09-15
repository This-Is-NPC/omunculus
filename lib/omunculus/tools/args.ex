defmodule Omunculus.Tools.Args do
  @moduledoc """
  Optional string arguments of the builtin tools: present only when given
  as a non-empty string.
  """

  @spec present(map, String.t()) :: String.t() | nil
  def present(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @spec put_present(map, String.t(), map) :: map
  def put_present(body, key, args) do
    case present(args, key) do
      nil -> body
      value -> Map.put(body, key, value)
    end
  end

  @spec missing(map, [String.t()]) :: String.t() | nil
  def missing(args, keys) do
    Enum.find_value(keys, fn key ->
      if present(args, key), do: nil, else: "#{key} required"
    end)
  end
end
