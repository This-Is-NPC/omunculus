defmodule Omunculus.Jobs.Summary do
  @moduledoc """
  A job in words, for the person who reads it: what it runs, when, as whom
  and the next fires of its schedule. The request `propose_job` raises and
  `jobs show` print the same lines.
  """

  alias Omunculus.{Jobs.Fields, Participant}
  alias Omunculus.Jobs.Schedule

  @previews 3

  @doc "The lines that describe `fields`, a job's fields (`Omunculus.Jobs.Fields`)."
  @spec lines(map) :: [String.t()]
  def lines(fields) do
    [
      target(fields),
      "when: #{fields["schedule"]} (#{fields["timezone"]})",
      next_fires(fields),
      owner(fields["owner"]),
      if(fields["delivery"] == "owner_inbox", do: "delivers: each reply to the owner's inbox"),
      if(fields["conversation_id"], do: "conversation: #{fields["conversation_id"]}"),
      if(fields["workspace"], do: "workspace: #{fields["workspace"]}"),
      if(fields["condition"], do: "only when #{fields["condition"]} passes"),
      if(fields["end_at"], do: "until: #{fields["end_at"]}")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp target(%{"agent" => agent, "message" => message}) when is_binary(agent),
    do: "runs: #{agent} is sent #{inspect(message)}"

  defp target(%{"workflow" => workflow, "message" => message}) when is_binary(workflow),
    do: "runs: the workflow #{workflow} is sent #{inspect(message)}"

  defp target(%{"tool" => tool}), do: "runs: the tool #{tool}, with no model"

  defp next_fires(fields) do
    with {:ok, schedule} <- Fields.parse(fields["schedule"], fields["timezone"]),
         [_ | _] = fires <- Schedule.next_fires(schedule, @previews) do
      "next fires: " <> Enum.map_join(fires, ", ", &Schedule.iso8601(schedule, &1))
    else
      _ -> nil
    end
  end

  defp owner(nil), do: nil
  defp owner(identity), do: "runs as: #{Participant.label(identity)}"
end
