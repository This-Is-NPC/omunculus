defmodule Omunculus.Tools.RequestWork do
  @moduledoc """
  Cross-lineage work request tool. The schema is what the model sees; the
  actual effect (append `task.requested`, route through the LCA, wait for the
  target's `task.completed`) is performed by `Omunculus.Runtime.Run`.
  """
  @behaviour Omunculus.Tool

  @impl true
  def name, do: "request_work"

  @impl true
  def schema do
    %{
      "name" => "request_work",
      "description" =>
        "Request work from another workspace, team, or agent. The request routes through the nearest common ancestor and returns when the target completes.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "work_item" => Omunculus.WorkItem.schema(),
          "workspace" => %{
            "type" => "string",
            "description" => "Target workspace"
          },
          "team" => %{
            "type" => "string",
            "description" => "Target team"
          },
          "agent" => %{
            "type" => "string",
            "description" => "Target agent within a team"
          }
        },
        "required" => ["work_item"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def call(_args, context), do: {:error, :request_work_unavailable, context}
end
