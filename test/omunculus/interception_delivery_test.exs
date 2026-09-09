defmodule Omunculus.Interception.DeliveryTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Omunculus.Interception.Delivery
  alias Omunculus.{EventCore, Config}
  alias Omunculus.Event.Envelope

  @policy %{
    "exclude" => ["payload.comment", "payload.report"],
    "exclude_items" => [
      %{
        "path" => "payload.checkpoint.messages",
        "match" => %{"role" => "assistant"},
        "missing" => ["tool_calls"]
      }
    ]
  }

  test "delivery removes final responses but preserves actual calls, returns and source" do
    source = %{
      "payload" => %{
        "comment" => "final",
        "report" => %{"comment" => "final", "completed" => true},
        "checkpoint" => %{
          "messages" => [
            %{"role" => "user", "content" => "task"},
            %{"role" => "assistant", "tool_calls" => [%{"id" => "call1"}]},
            %{"role" => "tool", "content" => "value=3"},
            %{"role" => "assistant", "content" => "final"},
            %{"role" => "user", "content" => "format correction"},
            %{"role" => "assistant", "content" => "final", "tool_calls" => nil}
          ]
        }
      }
    }

    projected = Delivery.project(source, @policy)
    refute Map.has_key?(projected["payload"], "comment")
    refute Map.has_key?(projected["payload"], "report")
    assert length(projected["payload"]["checkpoint"]["messages"]) == 4
    assert source["payload"]["comment"] == "final"
    assert Delivery.project(source, %{}) == source
    assert Delivery.project(%{}, @policy) == %{}
  end

  test "policy is applied directly to the source event for external actors and retries" do
    path = Path.join(System.tmp_dir!(), "delivery-#{System.unique_integer([:positive])}.sqlite3")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)

    rule = %{
      name: "editor",
      actor: "external:editor",
      events: ["run.completed"],
      enabled: true,
      wait: true,
      max_retries: 1,
      exclude: @policy["exclude"],
      exclude_items: @policy["exclude_items"],
      work_item: %{"instruction" => "Summarize"},
      response: %{"comment" => "string"},
      bindings: %{"comment" => "comment"}
    }

    {:ok, core} = start_supervised({EventCore, path: path, interceptors: [rule]})

    source =
      EventCore.append!(
        core,
        Envelope.event("run.completed",
          causation_id: "source",
          session_id: "s",
          payload: %{outcome: "reported", comment: "omit", report: %{comment: "omit"}}
        )
      )

    [request] = EventCore.stream(core, 0, type: "interception.requested")
    refute Map.has_key?(request.payload, "input")
    assert {:ok, delivered} = Delivery.for_request(core, request.event_id)
    assert delivered["event_id"] == source.event_id
    assert delivered["type"] == "run.completed"
    refute Map.has_key?(delivered["payload"], "comment")
    assert {:ok, raw} = EventCore.fetch(core, source.event_id)
    assert raw.payload["comment"] == "omit"

    output =
      capture_io(fn ->
        assert 0 ==
                 Omunculus.CLI.Events.events(%{
                   args: %{action: "show"},
                   flags: %{"db" => path, "request_id" => request.event_id}
                 })
      end)

    assert Jason.decode!(output) == delivered

    reply =
      EventCore.append!(
        core,
        Envelope.command("interception.responded",
          session_id: "s",
          correlation_id: request.correlation_id,
          payload: %{
            request_id: request.event_id,
            actor: "external:editor",
            outcome: "failed",
            error: "retry"
          }
        )
      )

    [_, retry] = EventCore.stream(core, 0, type: "interception.requested")
    assert {:ok, ^delivered} = Delivery.for_request(core, retry.event_id)

    assert Omunculus.Interception.resolve(:sys.get_state(core).conn, reply, fn _ ->
             flunk("Already handled")
           end).event_id == source.event_id

    assert {:error, {:invalid_interceptor_actor, "editor"}} =
             Config.check(%{Config.empty() | interceptors: [Map.put(rule, :exclude, "invalid")]})
  end

  test "rejects malformed selectors" do
    assert Delivery.valid?(@policy)

    for policy <- [
          nil,
          [],
          %{"exclude" => "payload.report"},
          %{"exclude" => ["payload..report"]},
          %{"exclude_items" => [%{"path" => "payload.messages"}]}
        ] do
      refute Delivery.valid?(policy)
    end
  end
end
