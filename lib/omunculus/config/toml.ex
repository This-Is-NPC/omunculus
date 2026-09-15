defmodule Omunculus.Config.Toml do
  @moduledoc """
  Encodes a nested map of string keys into TOML text: the writer
  `Omunculus.Config.grant/3` needs to persist a permanent grant back to
  `omunculus.toml`, nothing more. A list whose entries are all maps (a
  workflow's `steps`) renders as a list of inline tables.
  """

  @spec encode(map) :: String.t()
  def encode(map), do: render(map, [])

  defp render(map, path) do
    {tables, scalars} = Enum.split_with(map, fn {_key, value} -> is_map(value) end)

    scalar_lines =
      scalars
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> "#{format_key(key)} = #{format_value(value)}" end)
      |> Enum.join("\n")

    table_blocks =
      tables
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> render_table(value, path ++ [key]) end)

    [scalar_lines | table_blocks]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp render_table(map, path) do
    header = "[" <> Enum.map_join(path, ".", &format_key/1) <> "]"

    case render(map, path) do
      "" -> header
      body -> header <> "\n" <> body
    end
  end

  defp format_key(key) do
    if key =~ ~r/^[A-Za-z0-9_-]+$/, do: key, else: Jason.encode!(key)
  end

  defp format_value(value) when is_binary(value), do: Jason.encode!(value)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_value(value) when is_list(value) do
    if Enum.all?(value, &is_map/1) do
      "[ " <> Enum.map_join(value, ", ", &format_inline_table/1) <> " ]"
    else
      "[" <> Enum.map_join(value, ", ", &format_value/1) <> "]"
    end
  end

  defp format_inline_table(map) do
    fields =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(", ", fn {key, value} -> "#{format_key(key)} = #{format_value(value)}" end)

    "{ " <> fields <> " }"
  end
end
