defmodule Omunculus.CompleteMatrixTest do
  use ExUnit.Case, async: true
  alias Omunculus.{Chat.Fake, Config, EventCore, Harness, Matrix, Runtime}
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime.Agents

  for {base, depth} <- [
        {"simple", 0},
        {"medium", 1},
        {"medium-teams", 1},
        {"complex", 2},
        {"complex-teams", 2}
      ],
      task <- ["conte até 10", "escrever um README"] do
    test "#{base}: #{task}, identical behavior with and without lane" do
      base = unquote(base)
      task = unquote(task)
      without = run_case(base, unquote(depth), task, nil)
      with_lane = run_case(base, unquote(depth), task, "lane.toml")
      assert without == with_lane
    end
  end

  defp run_case(base, depth, task, overlay) do
    tmp = Harness.tmp_fixture(base <> ".toml", overlay)
    on_exit(fn -> File.rm_rf!(tmp.dir) end)
    {:ok, checked} = Config.check(tmp.config)

    core =
      start_supervised!({EventCore, path: ":memory:", interceptors: checked.interceptors},
        id: make_ref()
      )

    projector = start_supervised!({Projector, core: core}, id: make_ref())
    write? = String.contains?(task, "README")
    team = if write?, do: "edit", else: "count"
    teams? = Map.has_key?(tmp.config.teams, team)

    script = fn agent, at, _ws, _team, reason ->
      cond do
        reason == "continuation" ->
          [Fake.report(if(write?, do: "wrote README", else: "10"))]

        at < depth and agent not in ["counter", "editor"] ->
          args = %{
            "comment" => "Delegate and review " <> task,
            "work_item" => %{"instruction" => task},
            "workspace" => "app"
          }

          args = if teams? and at == 0, do: Map.put(args, "team", team), else: args
          [Fake.tool_call("delegate", args, "delegate")]

        write? ->
          [
            Fake.tool_call("write", %{"path" => "README.md", "content" => "# hi\n"}, "write"),
            Fake.report("wrote README")
          ]

        true ->
          Enum.map(1..10, &Fake.tool_call("counter", %{}, "count-#{&1}")) ++ [Fake.report("10")]
      end
    end

    runtime =
      start_supervised!(
        {Runtime,
         core: core,
         max_depth: depth,
         agents: Agents.resolver(script: script),
         config: [
           cwd: tmp.dir,
           config_file: tmp.overlay_path || tmp.path,
           env: %{},
           profile: if(write?, do: "coding", else: "count")
         ],
         run_opts: [fs: Omunculus.FS.Memory.new(%{})]},
        id: make_ref()
      )

    {:ok, %{requested: requested, result: result}} = Runtime.request(core, task, timeout: 3_000)
    assert result == if(write?, do: "wrote README", else: "10")
    await_idle(runtime, System.monotonic_time(:millisecond) + 3_000)
    events = EventCore.stream(core, 0, correlation_id: requested.correlation_id)

    completed =
      Enum.filter(
        events,
        &(&1.type == "tool.call.completed" and &1.payload["outcome"] == "completed")
      )

    assert length(completed) == if(write?, do: 1, else: 10)
    assert Enum.all?(completed, &(&1.payload["tool"] == if(write?, do: "write", else: "counter")))

    Matrix.contract_invariants!(%{
      core: core,
      projector: projector,
      correlation_id: requested.correlation_id
    })

    Enum.map(events, & &1.type)
  end

  defp await_idle(runtime, deadline) do
    unless Runtime.runs(runtime) == %{} do
      assert System.monotonic_time(:millisecond) < deadline, "runtime did not finish"
      Process.sleep(5)
      await_idle(runtime, deadline)
    end
  end
end
