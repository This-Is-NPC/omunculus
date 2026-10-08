defmodule Omunculus.Config.Toml do
  @moduledoc """
  Encodes a nested map of string keys into TOML text: the writer
  `Omunculus.Config.grant/3` and `Omunculus.Config.edit/5` need to put a
  permanent grant or an edited item back into `omunculus.toml`, nothing
  more. Text over several lines is a multi-line string. A list whose
  entries are all maps (a workflow's `steps`) renders as a list of inline
  tables, and a map inside one (a step's `overrides`) as a nested inline
  table.
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

  # Text over several lines, an agent's `text`, stays readable as a
  # multi-line string; the newline after the opening quotes is not part of it.
  defp format_value(value) when is_binary(value) do
    if String.contains?(value, "\n"),
      do: ~s(""") <> "\n" <> multiline(value) <> ~s("""),
      else: Jason.encode!(value)
  end

  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: to_string(value)
  defp format_value(value) when is_map(value), do: format_inline_table(value)

  defp format_value(value) when is_list(value) do
    if Enum.all?(value, &is_map/1) do
      "[ " <> Enum.map_join(value, ", ", &format_inline_table/1) <> " ]"
    else
      "[" <> Enum.map_join(value, ", ", &format_value/1) <> "]"
    end
  end

  defp multiline(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(~s("), ~s(\\"))
    |> String.replace(~r/[\x00-\x08\x0b-\x1f\x7f]/u, fn char ->
      <<code::utf8>> = char
      "\\u" <> String.pad_leading(Integer.to_string(code, 16), 4, "0")
    end)
  end

  defp format_inline_table(map) do
    fields =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(", ", fn {key, value} -> "#{format_key(key)} = #{format_value(value)}" end)

    "{ " <> fields <> " }"
  end
end
