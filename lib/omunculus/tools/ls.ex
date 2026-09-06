defmodule Omunculus.Tools.Ls do
  @moduledoc false
  @behaviour Omunculus.Tool

  alias Omunculus.{FS, Truncate}

  @impl true
  def name, do: "ls"

  @impl true
  def schema do
    %{
      "name" => "ls",
      "description" =>
        "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. Includes dotfiles. Output is truncated to 500 entries or 50KB.",
      "parameters" => %{
        "type" => "object",
        "required" => [],
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Directory to list (default: current directory)"
          },
          "limit" => %{
            "type" => "number",
            "description" => "Maximum number of entries to return (default: 500)"
          }
        }
      }
    }
  end

  @impl true
  def call(args, context) do
    fs = context.fs
    path = args["path"] || args[:path] || "."
    limit = trunc_int(args["limit"] || args[:limit], 500)

    case FS.list_dir(fs, path) do
      {:ok, entries} ->
        body =
          entries
          |> Enum.take(limit)
          |> Enum.join("\n")
          |> Truncate.text(max_bytes: 50 * 1024)

        {:ok, body, context}

      {:error, reason} ->
        {:error, reason, context}
    end
  end

  defp trunc_int(nil, default), do: default
  defp trunc_int(n, _) when is_integer(n), do: n
  defp trunc_int(n, _) when is_float(n), do: trunc(n)
  defp trunc_int(_, default), do: default
end
