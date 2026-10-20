defmodule Omunculus.Tools.Args do
  @moduledoc """
  String arguments of the builtin tools: present only when given as a
  non-empty string; a required one that is not is `"<key> required"`.
  A count argument is optional and, when given, a positive integer.
  """

  @spec count(map, String.t()) :: {:ok, pos_integer | nil} | {:error, String.t()}
  def count(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      n when is_integer(n) and n > 0 -> {:ok, n}
      _invalid -> {:error, "#{key} must be a positive integer"}
    end
  end

  @doc "Whether the flag `key` is set: true, or `\"true\"` from the command line."
  @spec flag?(map, String.t()) :: boolean
  def flag?(args, key), do: Map.get(args, key) in [true, "true"]

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

  @doc "Reads an object argument, also accepting its JSON spelling on the CLI."
  def object(args, key) do
    case Map.get(args, key, %{}) do
      value when is_map(value) ->
        {:ok, value}

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, object} when is_map(object) -> {:ok, object}
          _ -> {:error, "#{key} must be an object"}
        end

      _ ->
        {:error, "#{key} must be an object"}
    end
  end
end
