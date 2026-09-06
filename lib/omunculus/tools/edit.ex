defmodule Omunculus.Tools.Edit do
  @moduledoc false
  @behaviour Omunculus.Tool

  @impl true
  def name, do: "edit"

  @impl true
  def schema do
    %{
      "name" => "edit",
      "description" =>
        "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits. Do not include large unchanged regions just to connect distant changes.",
      "parameters" => %{
        "type" => "object",
        "required" => ["path", "edits"],
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file to edit (relative or absolute)"
          },
          "edits" => %{
            "type" => "array",
            "description" =>
              "One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits.",
            "items" => %{
              "type" => "object",
              "required" => ["oldText", "newText"],
              "properties" => %{
                "oldText" => %{
                  "type" => "string",
                  "description" =>
                    "Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call."
                },
                "newText" => %{
                  "type" => "string",
                  "description" => "Replacement text for this targeted edit."
                }
              }
            }
          }
        }
      }
    }
  end

  @impl true
  def call(args, context) do
    path = args["path"] || args[:path]
    edits = normalize_edits(args)

    with {:ok, original} <- Omunculus.FS.read_file(context.fs, path, %{}),
         {:ok, updated} <- apply_edits(original, edits),
         {:ok, fs} <- Omunculus.FS.write_file(context.fs, path, updated) do
      {:ok, "Edited #{path} (#{length(edits)} replacement(s))", %{context | fs: fs}}
    else
      {:error, reason} -> {:error, reason, context}
    end
  end

  defp normalize_edits(args) do
    cond do
      is_list(args["edits"]) ->
        args["edits"]

      is_list(args[:edits]) ->
        args[:edits]

      Map.has_key?(args, "oldText") or Map.has_key?(args, :oldText) ->
        [
          %{
            "oldText" => args["oldText"] || args[:oldText],
            "newText" => args["newText"] || args[:newText] || ""
          }
        ]

      true ->
        []
    end
  end

  defp apply_edits(_original, []), do: {:error, :no_edits}

  defp apply_edits(original, edits) do
    with {:ok, spans} <- spans(original, edits) do
      {:ok, splice(original, spans)}
    end
  end

  defp spans(original, edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {edit, idx}, {:ok, acc} ->
      old = edit["oldText"] || edit[:oldText]
      new = edit["newText"] || edit[:newText] || ""

      case locate(original, old) do
        {:ok, start, stop} ->
          span = %{start: start, stop: stop, new: new, idx: idx}

          if overlap?(span, acc) do
            {:halt, {:error, :overlapping_edits}}
          else
            {:cont, {:ok, [span | acc]}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp locate(_original, old) when old in [nil, ""], do: {:error, :empty_old_text}

  defp locate(original, old) do
    case :binary.matches(original, old) do
      [{start, len}] -> {:ok, start, start + len}
      [] -> {:error, :old_text_not_found}
      _ -> {:error, :old_text_not_unique}
    end
  end

  defp overlap?(span, spans) do
    Enum.any?(spans, fn other ->
      not (span.stop <= other.start or other.stop <= span.start)
    end)
  end

  defp splice(original, spans) do
    spans
    |> Enum.sort_by(& &1.start)
    |> Enum.reduce({[], 0}, fn span, {chunks, cursor} ->
      {[span.new, binary_part(original, cursor, span.start - cursor) | chunks], span.stop}
    end)
    |> then(fn {chunks, cursor} ->
      rest = binary_part(original, cursor, byte_size(original) - cursor)
      [rest | chunks] |> Enum.reverse() |> IO.iodata_to_binary()
    end)
  end
end
