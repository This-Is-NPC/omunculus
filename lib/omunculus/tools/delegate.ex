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
        "Delegate a task to a sub-agent. Returns the sub-agent's final result once it completes.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "instruction" => %{"type" => "string", "description" => "Task for the sub-agent"},
          "team" => %{
            "type" => "string",
            "description" => "Named team for depth-0 routing"
          },
          "agent" => %{
            "type" => "string",
            "description" => "Member name for depth-1 routing"
          }
        },
        "required" => ["instruction"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def call(_args, context), do: {:error, :delegate_unavailable, context}
end
