defmodule Omunculus.Tools.Write do
  @moduledoc false
  @behaviour Omunculus.Tool

  @impl true
  def name, do: "write"

  @impl true
  def schema do
    %{
      "name" => "write",
      "description" =>
        "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
      "parameters" => %{
        "type" => "object",
        "required" => ["path", "content"],
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file to write (relative or absolute)"
          },
          "content" => %{"type" => "string", "description" => "Content to write to the file"}
        }
      }
    }
  end

  @impl true
  def call(args, context) do
    path = args["path"] || args[:path]
    content = args["content"] || args[:content] || ""

    case Omunculus.FS.write_file(context.fs, path, content) do
      {:ok, fs} -> {:ok, "Wrote #{path}", %{context | fs: fs}}
      {:error, reason} -> {:error, reason, context}
    end
  end
end
