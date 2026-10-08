defmodule Omunculus.Tools.ReadWork do
  @moduledoc """
  Builtin `read_work` tool: what a work below the run's own is and what
  was done on it, for the agent above to judge it — its title, agent,
  state, stage and goal, every comment on it, and the record of each of
  its closed runs (`Omunculus.Tools.Record`, without the call that
  assembled each run's prompt). Reads the `target` view, which only
  reaches a work below the run's.
  """

  alias Omunculus.Tools.{Out, Record}

  @spec run(map) :: map
  def run(%{view: %{"target" => work}}) when is_map(work) do
    head = [
      "# #{work.title}",
      "agent: #{work.assignee} · state: #{work.state}" <> stage(work.stage),
      "## Goal\n#{work.goal}"
    ]

    comments =
      case work.comments do
        [] -> []
        comments -> ["## Comments\n" <> Enum.map_join(comments, "\n", &comment/1)]
      end

    runs = work.runs |> Enum.with_index(1) |> Enum.map(&run_section/1)

    Out.ok(Enum.join(head ++ comments ++ runs, "\n\n"))
  end

  def run(_input), do: Out.fail("work_id must name a work below this run's")

  defp stage(nil), do: ""
  defp stage(stage), do: " · stage: #{stage}"

  defp comment(comment), do: "- #{comment.author}: #{comment.body}"

  # The first call of a run is the one that assembled its prompt.
  defp run_section({run, index}) do
    opening =
      Enum.find_value(run.events, fn
        %{type: "tool", body: body} -> Jason.decode!(body)["name"]
        _event -> nil
      end)

    "## Run #{index} — #{run.agent}, via #{run.via}\n" <>
      Enum.join(Record.lines(run, opening, nil), "\n")
  end
end
