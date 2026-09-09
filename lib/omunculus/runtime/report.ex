defmodule Omunculus.Runtime.Report do
  @moduledoc "The model's completion flag and handoff comment; no semantic approval."

  def parse(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"completed" => completed, "comment" => comment} = report}
      when is_boolean(completed) and is_binary(comment) ->
        if Enum.all?(Map.keys(report), &(&1 in ["completed", "comment", "break"])) and
             String.trim(comment) != "" and is_boolean(Map.get(report, "break", false)) and
             not (completed and report["break"] == true) do
          {:ok, Map.take(report, ["completed", "comment", "break"])}
        else
          {:error, :invalid_report}
        end

      _ ->
        {:error, :invalid_report}
    end
  end

  def parse(_), do: {:error, :invalid_report}

  def instruction do
    """
    Use the exposed tools when an action is needed. Describing an action does not execute it.
    When returning your final report, return only a JSON object containing completed (boolean)
    and comment (nonempty string), without Markdown fences or text outside the object.
    completed describes whether the assigned work is complete, not whether you are ending a response.
    The comment summarizes the work, evidence and limitations. If work remains, include
    the correction or next instructions in comment, never in a separate field.
    Optional break=true requests intervention and requires completed=false.
    Follow each tool's schema. A tool request and a final report are separate response types.
    """
  end
end
