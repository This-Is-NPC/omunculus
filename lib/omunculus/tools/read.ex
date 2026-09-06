defmodule Omunculus.Tools.Read do
  @moduledoc false
  @behaviour Omunculus.Tool

  @impl true
  def name, do: "read"

  @impl true
  def schema do
    %{
      "name" => "read",
      "description" =>
        "Read the contents of a file. Supports text files. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
      "parameters" => %{
        "type" => "object",
        "required" => ["path"],
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file to read (relative or absolute)"
          },
          "offset" => %{
            "type" => "number",
            "description" => "Line number to start reading from (1-indexed)"
          },
          "limit" => %{"type" => "number", "description" => "Maximum number of lines to read"}
        }
      }
    }
  end

  @impl true
  def call(args, context) do
    path = args["path"] || args[:path]

    case Omunculus.FS.read_file(context.fs, path, args) do
      {:ok, body} -> {:ok, body, context}
      {:error, reason} -> {:error, reason, context}
    end
  end
end
