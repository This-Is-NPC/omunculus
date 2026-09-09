defmodule Omunculus.Tools.Delegate do
  @moduledoc """
  Delegation tool. The schema is what the model sees; the actual effect
  (append `task.delegated`, spawn a child Execution Node/Run, wait for its
  `task.completed`) is performed by `Omunculus.Runtime.Run`, which intercepts
  this tool before it reaches `call/2`. Outside the runtime it is unavailable.
  """
  @behaviour Omunculus.Tool

  @impl true
  def name, do: "delegate"

  @impl true
  def schema do
    %{
      "name" => "delegate",
      "description" =>
        "Create a child Work Item with constraints and expected evidence; comment carries the handoff context. Ends this execution; you resume with the child's report. Assess it and request a retry with your correction in comment if needed before concluding your own task.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "work_item" => Omunculus.WorkItem.schema(),
          "team" => %{
            "type" => "string",
            "description" =>
              "Known team to receive the work. Omit for default configured routing."
          },
          "agent" => %{
            "type" => "string",
            "description" =>
              "Known agent within the selected team. Not a tool name. Omit for default configured routing."
          }
        },
        "required" => ["work_item"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def call(_args, context), do: {:error, :delegate_unavailable, context}
end
