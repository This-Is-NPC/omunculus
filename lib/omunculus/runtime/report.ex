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
    End with a JSON object containing completed (boolean) and comment (nonempty string).
    The comment is your execution summary AND instructions for the next Run when work
    remains. Do not put instructions in a separate field. completed refers to the work,
    not whether this Run is ending. Use completed=false for unfinished work; the harness
    retries with your comment, up to max_retries, then emits break to your responsible.
    Optional break=true requests immediate escalation (completed must be false).
    In a break review, completed=true recognizes the target work as done without
    executing it again; false authorizes correction with your comment; break=true
    escalates to the next responsible. Judge evidence yourself.
    When making a request that ends this Run (delegate, request_work, request_permission),
    include a nonempty comment argument summarizing your work and handoff context.
    """
  end
end
