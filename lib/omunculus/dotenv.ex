defmodule Omunculus.Dotenv do
  @moduledoc false

  def load(dir) when is_binary(dir) do
    path = dir |> Path.expand() |> Path.join(".env")

    case File.read(path) do
      {:ok, body} -> parse(body)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:dotenv, reason}}
    end
  end

  def parse(body) when is_binary(body) do
    body
    |> String.split(~r/\R/)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {line, number}, {:ok, env} ->
      case parse_line(line) do
        :skip -> {:cont, {:ok, env}}
        {:ok, key, value} -> {:cont, {:ok, Map.put(env, key, value)}}
        :error -> {:halt, {:error, {:invalid_dotenv, number}}}
      end
    end)
  end

  defp parse_line(line) do
    line = line |> String.trim() |> String.replace_prefix("export ", "")

    cond do
      line == "" or String.starts_with?(line, "#") ->
        :skip

      true ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> parse_pair(String.trim(key), String.trim(value))
          _ -> :error
        end
    end
  end

  defp parse_pair(key, value) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) do
      {:ok, key, unquote_value(value)}
    else
      :error
    end
  end

  defp unquote_value(<<quote, rest::binary>>) when quote in [?", ?'] do
    if String.ends_with?(rest, <<quote>>) do
      binary_part(rest, 0, byte_size(rest) - 1)
    else
      <<quote, rest::binary>>
    end
  end

  defp unquote_value(value) do
    case Regex.run(~r/^(.*?)\s+#.*$/, value) do
      [_, content] -> String.trim_trailing(content)
      _ -> value
    end
  end
end
