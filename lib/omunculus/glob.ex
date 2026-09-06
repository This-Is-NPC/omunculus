defmodule Omunculus.Glob do
  @moduledoc false

  def match?(nil, _path), do: true
  def match?("", _path), do: true

  def match?(pattern, path) when is_binary(pattern) and is_binary(path) do
    path = String.replace(path, "\\", "/")
    pattern = String.replace(pattern, "\\", "/")
    regex = to_regex(pattern)

    Regex.match?(regex, path) or
      (not String.contains?(pattern, "/") and Regex.match?(regex, Path.basename(path)))
  end

  defp to_regex(pattern) do
    pattern
    |> String.replace("\\", "/")
    |> escape_and_expand()
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  defp escape_and_expand(pattern) do
    pattern
    |> String.to_charlist()
    |> expand([])
    |> IO.iodata_to_binary()
  end

  defp expand([], acc), do: Enum.reverse(acc)

  defp expand([?* | rest], acc) do
    case rest do
      [?* | rest2] ->
        rest2 =
          case rest2 do
            [?/ | more] -> more
            _ -> rest2
          end

        expand(rest2, [".*" | acc])

      _ ->
        expand(rest, ["[^/]*" | acc])
    end
  end

  defp expand([?? | rest], acc), do: expand(rest, ["[^/]" | acc])

  defp expand([c | rest], acc) do
    expand(rest, [Regex.escape(<<c>>) | acc])
  end
end
