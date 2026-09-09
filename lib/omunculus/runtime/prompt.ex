defmodule Omunculus.Runtime.Prompt do
  @moduledoc "Configured agent identity and the shared response contract."

  def compose(name, role, response \\ nil) do
    """
    You are #{name}.
    #{role}

    #{contract(response)}
    """
  end

  defp contract(nil), do: Omunculus.Runtime.Report.instruction()

  defp contract(response) do
    """
    Return only a JSON object with exactly these required fields and types:
    #{Jason.encode!(response)}
    String fields must be nonempty. No Markdown fences or text outside the object.
    This response belongs to the requested event processing, not to the task described
    inside the event. Do not add task approval, completion flags or intervention fields
    unless explicitly required by the response schema. Report failures in the source
    as facts; they do not prevent producing a valid response.
    """
  end
end
