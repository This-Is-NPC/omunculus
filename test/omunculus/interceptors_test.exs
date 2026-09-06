defmodule Omunculus.InterceptorsTest do
  @moduledoc "docs/to-be/event-catalog.md: catalog, interceptor lane, automations, config check."
  use ExUnit.Case, async: true

  alias Omunculus.{Automations, Config, Events}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime
  alias Omunculus.Runtime.SpikeAgents

  @depth_gate %{
    name: "depth-gate",
    events: ["task.delegated"],
    module: Omunculus.Interceptors.DepthGate,
    options: %{"max_depth" => 1}
  }

  @audit %{
    name: "audit",
    events: ["task.requested", "task.completed"],
    module: Omunculus.Interceptors.Audit,
    options: %{}
  }

  defp boot(max_depth, interceptors) do
    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: interceptors)
    {:ok, projector} = Projector.start_link(core: core)

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        max_depth: max_depth,
        agents: SpikeAgents.resolver(),
        run_opts: [delegation_timeout: 2_000]
      )

    %{core: core, projector: projector, runtime: runtime}
  end

  describe "catalog" do
    test "every type the runtime emits is declared, and unknown types are rejected" do
      {:ok, core} = EventCore.start_link(path: ":memory:")

      assert {:error, {:unknown_event_type, "task.exploded"}} =
               EventCore.append(core, Envelope.command("task.exploded"))

      assert {:error, {:kind_mismatch, "run.started", :command}} =
               EventCore.append(core, Envelope.command("run.started"))

      assert {:error, {:missing_payload_fields, "task.requested", ["instruction"]}} =
               EventCore.append(core, Envelope.command("task.requested"))

      assert {:error, {:unsupported_schema_version, "task.requested", "9"}} =
               EventCore.append(
                 core,
                 Envelope.command("task.requested",
                   schema_version: "9",
                   payload: %{instruction: "x"}
                 )
               )

      assert Events.injectable?("task.requested")
      refute Events.injectable?("task.completed")
      assert Events.markdown() =~ "| `delivery.rejected` | event |"
    end
  end

  describe "interceptor lane" do
    test "an observe-only interceptor changes nothing in the log" do
      %{core: core} = boot(1, [@audit])
      {:ok, %{result: "10", requested: requested}} = Runtime.request(core, "conte até 10")

      types =
        core
        |> EventCore.stream(0, correlation_id: requested.correlation_id)
        |> Enum.map(& &1.type)

      refute "delivery.rejected" in types
      assert Enum.count(types, &(&1 == "task.completed")) == 2

      assert %{"audit" => %{evaluated: 3, delivered: 3, rejected: 0}} =
               EventCore.interceptor_stats(core)
    end

    test "a rejecting interceptor blocks delivery and records delivery.rejected with causation" do
      # Runtime allows depth 2, the configured lane allows only 1.
      %{core: core, projector: projector} = boot(2, [@depth_gate])

      # The rejection reaches the delegating Run as a tool error; the model
      # decides what to do with it. The scripted concierge just reports.
      {:ok, %{result: "", requested: requested}} = Runtime.request(core, "conte até 10")

      events = EventCore.stream(core, 0, correlation_id: requested.correlation_id)
      delegated = Enum.filter(events, &(&1.type == "task.delegated"))
      [rejected] = Enum.filter(events, &(&1.type == "delivery.rejected"))

      assert [%{payload: %{"to_depth" => 1}}, %{payload: %{"to_depth" => 2}} = second] = delegated
      assert rejected.causation_id == second.event_id
      assert rejected.payload["interceptor"] == "depth-gate"
      assert rejected.payload["rejected_event_id"] == second.event_id

      # The rejected delegation never activated a depth-2 run.
      depths =
        events |> Enum.filter(&(&1.type == "run.started")) |> Enum.map(& &1.payload["depth"])

      assert depths == [0, 1]
      refute Enum.any?(events, &(&1.type == "run.failed"))

      # The depth-1 completion is caused by the rejection: the decision is in the chain.
      [depth1_done, _root_done] = Enum.filter(events, &(&1.type == "task.completed"))
      assert depth1_done.causation_id == rejected.event_id

      assert %{"depth-gate" => %{evaluated: 2, delivered: 1, rejected: 1}} =
               EventCore.interceptor_stats(core)

      :ok = Projector.sync(projector)
      before = Projector.snapshot(core)
      :ok = Projector.rebuild(projector)
      assert Projector.snapshot(core) == before
    end
  end

  describe "automations" do
    test "run an external command per matching event with a durable cursor" do
      %{core: core} = boot(1, [])

      out =
        Path.join(
          System.tmp_dir!(),
          "omunculus-automation-#{System.unique_integer([:positive])}.log"
        )

      automations = [
        %{
          name: "log-completed",
          events: ["task.completed"],
          run: ~s(printf '%s %s\\n' "$OMUNCULUS_EVENT_TYPE" "$OMUNCULUS_EVENT_ID" >> "#{out}")
        },
        %{name: "always-fails", events: ["run.started"], run: "exit 3"}
      ]

      {:ok, pid} = Automations.start_link(core: core, automations: automations)
      {:ok, %{requested: requested}} = Runtime.request(core, "conte até 3")
      :ok = Automations.sync(pid)

      completed =
        EventCore.stream(core, 0,
          correlation_id: requested.correlation_id,
          type: "task.completed"
        )

      lines = out |> File.read!() |> String.split("\n", trim: true)
      assert lines == Enum.map(completed, &"task.completed #{&1.event_id}")

      assert %{
               "log-completed" => %{delivered: 2, failed: 0},
               "always-fails" => %{delivered: 0, failed: 2}
             } =
               Automations.stats(pid)

      # Cursor is durable per automation; a restart does not re-run the script.
      GenServer.stop(pid)
      {:ok, pid} = Automations.start_link(core: core, automations: automations)
      :ok = Automations.sync(pid)
      assert File.read!(out) |> String.split("\n", trim: true) |> length() == 2
      File.rm(out)
    end
  end

  describe "config check" do
    test "resolves modules and rejects unknown or non-interceptable types" do
      base = Config.empty()

      ok = %{
        base
        | interceptors: [
            %{
              name: "g",
              events: ["task.delegated"],
              module: "Omunculus.Interceptors.DepthGate",
              options: %{}
            }
          ],
          automations: [%{name: "n", events: ["run.failed"], run: "true"}]
      }

      assert {:ok,
              %{interceptors: [%{module: Omunculus.Interceptors.DepthGate}], automations: [_]}} =
               Config.check(ok)

      assert {:error, {:unknown_event_type, "g", "task.nope"}} =
               Config.check(%{
                 ok
                 | interceptors: [%{name: "g", events: ["task.nope"], module: "X", options: %{}}]
               })

      assert {:error, {:not_interceptable, "g", "run.started"}} =
               Config.check(%{
                 ok
                 | interceptors: [
                     %{name: "g", events: ["run.started"], module: "X", options: %{}}
                   ]
               })

      assert {:error, {:unknown_interceptor_module, "Nope.Module"}} =
               Config.check(%{
                 ok
                 | interceptors: [
                     %{name: "g", events: ["task.delegated"], module: "Nope.Module", options: %{}}
                   ]
               })

      assert {:error, {:automation_requires_run, "n"}} =
               Config.check(%{ok | automations: [%{name: "n", events: ["run.failed"], run: nil}]})
    end

    test "sections are parsed from TOML and merged across files" do
      dir = Path.join(System.tmp_dir!(), "omunculus-cfg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "omunculus.toml")

      File.write!(path, """
      [[interceptors]]
      name = "depth-gate"
      events = ["task.delegated"]
      module = "Omunculus.Interceptors.DepthGate"
      options = { max_depth = 2 }

      [[automations]]
      name = "notify"
      events = ["task.completed", "run.failed"]
      run = "./hooks/notify.sh"
      """)

      {:ok, config} = Config.load(cwd: dir, config_file: path, env: %{})
      assert [%{name: "depth-gate", options: %{"max_depth" => 2}}] = config.interceptors
      assert [%{name: "notify", events: ["task.completed", "run.failed"]}] = config.automations
      assert {:ok, _} = Config.check(config)
      File.rm_rf!(dir)
    end
  end
end
