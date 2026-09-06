defmodule Omunculus.Tools.Grep do
  @moduledoc false
  @behaviour Omunculus.Tool

  alias Omunculus.{FS, Truncate}

  @impl true
  def name, do: "grep"

  @impl true
  def schema do
    %{
      "name" => "grep",
      "description" =>
        "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Output is truncated to 100 matches or 50KB.",
      "parameters" => %{
        "type" => "object",
        "required" => ["pattern"],
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Search pattern (regex or literal string)"
          },
          "path" => %{
            "type" => "string",
            "description" => "Directory or file to search (default: current directory)"
          },
          "glob" => %{
            "type" => "string",
            "description" => "Filter files by glob pattern, e.g. '*.ts'"
          },
          "ignoreCase" => %{
            "type" => "boolean",
            "description" => "Case-insensitive search (default: false)"
          },
          "literal" => %{
            "type" => "boolean",
            "description" => "Treat pattern as literal string instead of regex (default: false)"
          },
          "context" => %{
            "type" => "number",
            "description" => "Number of lines to show before and after each match (default: 0)"
          },
          "limit" => %{
            "type" => "number",
            "description" => "Maximum number of matches to return (default: 100)"
          }
        }
      }
    }
  end

  @impl true
  def call(args, tool_context) do
    fs = tool_context.fs
    pattern = args["pattern"] || args[:pattern]
    path = args["path"] || args[:path] || "."
    glob = args["glob"] || args[:glob]
    ignore_case? = truthy?(args["ignoreCase"] || args[:ignoreCase])
    literal? = truthy?(args["literal"] || args[:literal])
    context = trunc_int(args["context"] || args[:context], 0)
    limit = trunc_int(args["limit"] || args[:limit], 100)

    with {:ok, regex} <- compile(pattern, ignore_case?, literal?),
         {:ok, files} <- FS.walk_files(fs, path) do
      cwd = FS.cwd(fs)

      matches =
        files
        |> Enum.filter(&match_glob?(&1, cwd, glob))
        |> Enum.flat_map(&grep_file(fs, &1, cwd, regex, context))
        |> Enum.take(limit)

      body =
        case matches do
          [] -> "No matches."
          rows -> Truncate.text(Enum.join(rows, "\n"), max_bytes: 50 * 1024)
        end

      {:ok, body, tool_context}
    else
      {:error, reason} -> {:error, reason, tool_context}
    end
  end

  defp compile(nil, _, _), do: {:error, :missing_pattern}
  defp compile("", _, _), do: {:error, :missing_pattern}

  defp compile(pattern, ignore_case?, true) do
    opts = if ignore_case?, do: [:caseless], else: []
    Regex.compile(Regex.escape(pattern), opts)
  end

  defp compile(pattern, ignore_case?, _) do
    opts = if ignore_case?, do: [:caseless], else: []
    Regex.compile(pattern, opts)
  end

  defp grep_file(fs, abs, cwd, regex, context) do
    rel = Path.relative_to(abs, cwd)

    case FS.read_file(fs, rel, %{}) do
      {:ok, body} ->
        lines = String.split(body, "\n")
        last = length(lines) - 1

        lines
        |> Enum.with_index()
        |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
        |> Enum.map(fn {_line, idx} ->
          lo = max(idx - context, 0)
          hi = min(idx + context, last)

          lo..hi
          |> Enum.map(fn i -> "#{rel}:#{i + 1}:#{Enum.at(lines, i)}" end)
          |> Enum.join("\n")
        end)

      {:error, _} ->
        []
    end
  end

  defp match_glob?(_abs, _cwd, nil), do: true
  defp match_glob?(_abs, _cwd, ""), do: true

  defp match_glob?(abs, cwd, glob) do
    rel = Path.relative_to(abs, cwd)
    Omunculus.Glob.match?(glob, rel) or Omunculus.Glob.match?(glob, Path.basename(rel))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp trunc_int(nil, default), do: default
  defp trunc_int(n, _) when is_integer(n), do: n
  defp trunc_int(n, _) when is_float(n), do: trunc(n)
  defp trunc_int(_, default), do: default
end
