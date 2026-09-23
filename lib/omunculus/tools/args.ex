defmodule Omunculus.Tools.Args do
  @moduledoc """
  String arguments of the builtin tools: present only when given as a
  non-empty string; a required one that is not is `"<key> required"`.
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

  @spec fetch(map, String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch(args, key) do
    case present(args, key) do
      nil -> {:error, "#{key} required"}
      value -> {:ok, value}
    end
  end

  @spec missing(map, [String.t()]) :: String.t() | nil
  def missing(args, keys) do
    Enum.find_value(keys, fn key ->
      case fetch(args, key) do
        {:ok, _value} -> nil
        {:error, message} -> message
      end
    end)
  end
end
