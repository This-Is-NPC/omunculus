defmodule Omunculus.Tools.Find do
  @moduledoc false
  @behaviour Omunculus.Tool

  alias Omunculus.{FS, Truncate}

  @impl true
  def name, do: "find"

  @impl true
  def schema do
    %{
      "name" => "find",
      "description" =>
        "Search for files by glob pattern. Returns matching file paths relative to the search directory. Output is truncated to 1000 results or 50KB.",
      "parameters" => %{
        "type" => "object",
        "required" => ["pattern"],
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Glob pattern, e.g. '*.ts' or 'src/**/*.ex'"
          },
          "path" => %{
            "type" => "string",
            "description" => "Directory to search in (default: current directory)"
          },
          "limit" => %{
            "type" => "number",
            "description" => "Maximum number of results (default: 1000)"
          }
        }
      }
    }
  end

  @impl true
  def call(args, context) do
    fs = context.fs
    pattern = args["pattern"] || args[:pattern]
    path = args["path"] || args[:path] || "."
    limit = trunc_int(args["limit"] || args[:limit], 1000)

    with {:ok, files} <- FS.walk_files(fs, path) do
      cwd = FS.cwd(fs)
      root = Path.expand(path, cwd)

      hits =
        files
        |> Enum.map(&Path.relative_to(&1, root))
        |> Enum.filter(&Omunculus.Glob.match?(pattern, &1))
        |> Enum.take(limit)

      body =
        case hits do
          [] -> "No files matched."
          rows -> Truncate.text(Enum.join(rows, "\n"), max_bytes: 50 * 1024)
        end

      {:ok, body, context}
    else
      {:error, reason} -> {:error, reason, context}
    end
  end

  defp trunc_int(nil, default), do: default
  defp trunc_int(n, _) when is_integer(n), do: n
  defp trunc_int(n, _) when is_float(n), do: trunc(n)
  defp trunc_int(_, default), do: default
end
