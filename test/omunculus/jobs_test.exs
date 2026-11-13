defmodule Omunculus.JobsTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.{Fixtures, Jobs, Store}
  alias Omunculus.Store.Query

  @jobs """
  [jobs]
  max_parallel = 2
  min_interval_minutes = 5
  max_jobs = 3
  missed = "skip"
  lateness_seconds = 60
  failures_before_pause = 3
  agent_may_create = false
  """

  @agents """
  [agents.front]
  depth = 0
  text = "front"

  [agents.helper]
  depth = 1
  text = "helper"

  [workflows.review]
  steps = [{ name = "look", agent = "helper" }]

  [accounts]
  boss = { kind = "human", issuer = "acme", subject = "boss" }
  """

  @call %{name: "jobs", args: %{}, ok: true, output: ""}

  defp config(jobs \\ @jobs), do: Fixtures.config(@agents <> "\n" <> jobs)

  defp ctx(config, fields \\ %{}) do
    Map.merge(
      %{
        run_id: nil,
        work_id: nil,
        author: "human",
        agent: nil,
        issuer: "local",
        subject: "1000",
        config: config,
        groups: %{}
      },
      fields
    )
  end

  defp emit(body), do: %{"type" => "job", "body" => body}

  defp write(conn, body, ctx),
    do: Store.record_tools(conn, ctx.run_id, [{@call, [emit(body)]}], ctx)

  @review %{
    "op" => "create",
    "name" => "review",
    "agent" => "front",
    "message" => "Review the open pull requests.",
    "schedule" => "every 1h",
    "timezone" => "UTC"
  }

  defp create(conn, ctx, fields \\ %{}) do
    {:ok, _events} = write(conn, Map.merge(@review, fields), ctx)
    {:ok, job} = Jobs.get(conn, fields["name"] || "review")
    job
  end

  defp refused(conn, body, ctx) do
    assert {:error, {:jobs, reason}} = write(conn, body, ctx)
    reason
  end

  describe "create" do
    test "stores a job with its origin and owner, read back with its next fire", %{conn: conn} do
      ctx = ctx(config())
      job = create(conn, ctx)

      assert %{
               "name" => "review",
               "state" => "active",
               "version" => 1,
               "agent" => "front",
               "workflow" => nil,
               "schedule" => "every 1h",
               "owner" => %{"kind" => "human", "issuer" => "local", "subject" => "1000"},
               "origin" => %{
                 "author" => %{"kind" => "human", "subject" => "1000"},
                 "channel" => "cli",
                 "request_id" => nil
               },
               "fires" => %{"fires" => 0, "usd" => +0.0, "success_rate" => nil},
               "last_fire" => nil
             } = job

      assert {:ok, next, _} = DateTime.from_iso8601(job["next_fire"])
      assert DateTime.diff(next, DateTime.utc_now()) in 3590..3600

      assert {:ok, [^job]} = Jobs.list(conn)
      assert {:ok, ^job} = Jobs.get(conn, job["id"])
    end

    test "names the owner as an account, and the channel the call came by", %{conn: conn} do
      job = create(conn, ctx(config()), %{"owner" => "boss", "channel" => "console"})
      assert job["owner"] == %{"kind" => "human", "issuer" => "acme", "subject" => "boss"}
      assert job["origin"]["channel"] == "console"
    end

    test "aims at a workflow or at a tool with arguments", %{conn: conn} do
      ctx = ctx(config())

      assert %{"workflow" => "review", "agent" => nil} =
               create(conn, ctx, %{
                 "name" => "flow",
                 "agent" => nil,
                 "workflow" => "review",
                 "condition" => "paid",
                 "condition_args" => %{"plan" => "weekly"}
               })

      assert %{"tool" => "report", "args" => %{"to" => "x"}, "message" => nil} =
               create(conn, ctx, %{
                 "name" => "plain",
                 "agent" => nil,
                 "message" => nil,
                 "tool" => "report",
                 "args" => %{"to" => "x"}
               })
    end

    test "is refused without a [jobs] table", %{conn: conn} do
      assert :disabled = refused(conn, @review, ctx(Fixtures.config(@agents)))
    end

    test "is refused for what is not a valid job", %{conn: conn} do
      ctx = ctx(config())

      assert :one_target = refused(conn, Map.put(@review, "workflow", "review"), ctx)
      assert {:unknown_agent, "helper"} = refused(conn, %{@review | "agent" => "helper"}, ctx)
      assert {:unknown_agent, "nobody"} = refused(conn, %{@review | "agent" => "nobody"}, ctx)

      assert {:unknown_workflow, "none"} =
               refused(conn, Map.merge(@review, %{"agent" => nil, "workflow" => "none"}), ctx)

      assert {:invalid, "message"} = refused(conn, %{@review | "message" => " "}, ctx)
      assert {:invalid, "schedule"} = refused(conn, %{@review | "schedule" => "sometimes"}, ctx)
      assert {:invalid, "schedule"} = refused(conn, %{@review | "schedule" => "0 0 31 2 *"}, ctx)

      assert {:unknown_timezone, "Mars/Base"} =
               refused(conn, %{@review | "timezone" => "Mars/Base"}, ctx)

      assert {:invalid, "name"} = refused(conn, %{@review | "name" => "has space"}, ctx)
      assert {:unknown_account, "ghost"} = refused(conn, Map.put(@review, "owner", "ghost"), ctx)
      assert {:invalid, "end_at"} = refused(conn, Map.put(@review, "end_at", "soon"), ctx)

      assert {:unknown_conversation, "none"} =
               refused(conn, Map.put(@review, "conversation_id", "none"), ctx)

      assert {:invalid, "args"} = refused(conn, Map.put(@review, "args", %{"a" => 1}), ctx)
      assert {:invalid, "channel"} = refused(conn, Map.put(@review, "channel", "carrier"), ctx)
      assert {:invalid, "state"} = refused(conn, Map.put(@review, "state", "ended"), ctx)
      assert {:invalid, "op"} = refused(conn, %{"op" => "burn"}, ctx)
    end

    test "is refused past the limits and for a name taken", %{conn: conn} do
      ctx = ctx(config())

      assert {:too_frequent, 60, 300} =
               refused(conn, %{@review | "schedule" => "every 1m"}, ctx)

      assert {:too_frequent, 60, 300} =
               refused(conn, %{@review | "schedule" => "* * * * *"}, ctx)

      create(conn, ctx)
      assert {:name_taken, "review"} = refused(conn, @review, ctx)
      create(conn, ctx, %{"name" => "two"})
      create(conn, ctx, %{"name" => "three"})
      assert {:too_many, 3} = refused(conn, %{@review | "name" => "four"}, ctx)
    end

    test "an archived job frees its name and its place", %{conn: conn} do
      ctx = ctx(config())
      create(conn, ctx)
      {:ok, _} = write(conn, %{"op" => "transition", "job" => "review", "to" => "archived"}, ctx)
      assert %{"version" => 1, "state" => "active"} = create(conn, ctx)
    end

    test "a draft starts proposed and resume starts it", %{conn: conn} do
      ctx = ctx(config())

      assert %{"state" => "proposed", "next_fire" => nil} =
               create(conn, ctx, %{"state" => "proposed"})

      {:ok, _} = write(conn, %{"op" => "transition", "job" => "review", "to" => "active"}, ctx)
      assert {:ok, %{"state" => "active", "next_fire" => next}} = Jobs.get(conn, "review")
      assert next
    end

    test "is refused in the project's own conversation only when it exists", %{conn: conn} do
      conversation = Omunculus.Id.new()

      :ok =
        Query.insert(conn, :conversations, %{
          id: conversation,
          created_at: "2026-01-01T00:00:00Z",
          created_issuer: "local",
          created_subject: "1000"
        })

      assert %{"conversation_id" => ^conversation} =
               create(conn, ctx(config()), %{"conversation_id" => conversation})
    end
  end

  describe "change" do
    test "bumps the version, keeps the rest and records what changed", %{conn: conn} do
      ctx = ctx(config())
      create(conn, ctx)

      assert {:ok, _} =
               write(
                 conn,
                 %{
                   "op" => "change",
                   "job" => "review",
                   "message" => "Twice.",
                   "channel" => "api"
                 },
                 ctx
               )

      assert {:ok, %{"version" => 2, "message" => "Twice.", "agent" => "front"} = job} =
               Jobs.get(conn, "review")

      assert job["origin"]["channel"] == "api"

      assert {:ok, [%{"op" => "create"}, %{"op" => "change", "version" => 2, "fields" => fields}]} =
               Jobs.history(conn, "review")

      assert fields == %{"message" => "Twice."}
    end

    test "an empty text clears an optional field, and a schedule change restarts the count", %{
      conn: conn
    } do
      ctx = ctx(config())
      first = create(conn, ctx, %{"workspace" => nil, "condition" => "paid"})

      {:ok, _} =
        write(
          conn,
          %{"op" => "change", "job" => "review", "condition" => "", "schedule" => "every 2h"},
          ctx
        )

      assert {:ok, %{"condition" => nil, "condition_args" => nil, "anchor" => anchor}} =
               Jobs.get(conn, "review")

      assert anchor >= first["anchor"]
    end

    test "is refused when it changes nothing, the conversation, or is not valid", %{conn: conn} do
      ctx = ctx(config())
      create(conn, ctx)
      change = %{"op" => "change", "job" => "review"}

      assert :unchanged = refused(conn, Map.put(change, "message", @review["message"]), ctx)

      assert {:invalid, "conversation_id"} =
               refused(conn, Map.put(change, "conversation_id", "x"), ctx)

      assert {:too_frequent, 60, 300} =
               refused(conn, Map.put(change, "schedule", "every 1m"), ctx)

      assert {:unknown, "ghost"} = refused(conn, %{change | "job" => "ghost"}, ctx)
    end

    test "an archived job takes no change", %{conn: conn} do
      ctx = ctx(config())
      job = create(conn, ctx)
      {:ok, _} = write(conn, %{"op" => "transition", "job" => "review", "to" => "archived"}, ctx)

      assert {:state, "archived", "change"} =
               refused(conn, %{"op" => "change", "job" => job["id"], "message" => "x"}, ctx)
    end
  end

  describe "states" do
    test "move as the lifecycle allows, with the reason kept", %{conn: conn} do
      ctx = ctx(config())
      %{"id" => id} = create(conn, ctx)

      move =
        &write(conn, %{"op" => "transition", "job" => "review", "to" => &1, "reason" => &2}, ctx)

      assert {:ok, _} = move.("paused", "holiday")

      assert {:ok, %{"state" => "paused", "state_reason" => "holiday", "next_fire" => nil}} =
               Jobs.get(conn, "review")

      assert {:ok, _} = move.("active", nil)

      assert {:state, "active", "proposed"} =
               refused(conn, %{"op" => "transition", "job" => "review", "to" => "proposed"}, ctx)

      assert {:ok, _} = move.("archived", "done")

      assert {:state, "archived", "active"} =
               refused(conn, %{"op" => "transition", "job" => id, "to" => "active"}, ctx)

      assert {:ok, []} = Jobs.list(conn)

      assert {:ok, [_create, %{"from" => "active", "to" => "paused", "reason" => "holiday"} | _]} =
               Jobs.history(conn, id)
    end

    test "transition/5 is the scheduler's, authored by the harness", %{conn: conn} do
      create(conn, ctx(config()))
      assert {:ok, _} = Jobs.transition(conn, "review", "paused", "3 failures in a row")
      assert {:ok, %{"state" => "paused"}} = Jobs.get(conn, "review")

      assert {:ok, history} = Jobs.history(conn, "review", 1)

      assert [
               %{
                 "op" => "transition",
                 "origin" => %{"author" => %{"kind" => "harness"}, "channel" => "scheduler"}
               }
             ] =
               history

      assert {:state, "paused", "proposed"} =
               elem(Jobs.transition(conn, "review", "proposed", nil), 1) |> elem(1)
    end

    test "duplicate copies a job as a draft", %{conn: conn} do
      ctx = ctx(config())
      source = create(conn, ctx)
      {:ok, _} = write(conn, %{"op" => "duplicate", "job" => "review", "name" => "copy"}, ctx)

      assert {:ok, %{"state" => "proposed", "message" => message, "version" => 1}} =
               Jobs.get(conn, "copy")

      assert message == source["message"]
    end
  end

  describe "fires" do
    setup %{conn: conn} do
      ctx = ctx(config())
      %{job: create(conn, ctx), ctx: ctx}
    end

    test "run queues a manual fire that is no slot", %{conn: conn, ctx: ctx} do
      assert {:ok, _} = write(conn, %{"op" => "run", "job" => "review"}, ctx)
      assert {:ok, [%{"state" => "due", "manual" => true, "version" => 1}]} = Jobs.pending(conn)
      assert {:ok, %{"next_fire" => next}} = Jobs.get(conn, "review")

      assert {:ok, [%{job: _, slots: slots}]} =
               Jobs.due(conn, DateTime.add(DateTime.utc_now(), 90 * 60))

      assert length(Enum.to_list(slots)) == 1
      assert next
    end

    test "a fire goes due, running and finished, and the job totals what it cost", %{conn: conn} do
      slot = "2026-01-01T00:00:00Z"

      assert {:ok, %{"fire_id" => id}} =
               Jobs.record_fire(conn, "review", %{"state" => "due", "scheduled_for" => slot})

      assert {:ok, [%{"fire_id" => ^id, "state" => "due"}]} = Jobs.pending(conn)

      assert {:ok, _} =
               Jobs.record_fire(conn, "review", %{
                 "fire_id" => id,
                 "state" => "running",
                 "conversation_id" => "c1",
                 "run_ids" => ["r1"]
               })

      assert {:ok, _} =
               Jobs.record_fire(conn, "review", %{
                 "fire_id" => id,
                 "state" => "succeeded",
                 "duration_ms" => 1500,
                 "calls" => 3,
                 "input_tokens" => 1000,
                 "output_tokens" => 200,
                 "usd" => 0.25
               })

      assert {:ok, []} = Jobs.pending(conn)

      assert {:ok,
              [
                %{
                  "state" => "succeeded",
                  "scheduled_for" => ^slot,
                  "conversation_id" => "c1",
                  "run_ids" => ["r1"],
                  "usd" => 0.25,
                  "version" => 1
                }
              ]} = Jobs.fires(conn, "review")

      {:ok, %{"fire_id" => skipped}} =
        Jobs.record_fire(conn, "review", %{
          "state" => "due",
          "scheduled_for" => "2026-01-01T01:00:00Z"
        })

      {:ok, _} =
        Jobs.record_fire(conn, "review", %{
          "fire_id" => skipped,
          "state" => "skipped",
          "reason" => "not entitled"
        })

      assert {:ok,
              %{
                "fires" => totals,
                "last_fire" => %{"state" => "skipped", "reason" => "not entitled"}
              }} =
               Jobs.get(conn, "review")

      assert %{
               "fires" => 2,
               "succeeded" => 1,
               "skipped" => 1,
               "failed" => 0,
               "usd" => 0.25,
               "calls" => 3,
               "input_tokens" => 1000,
               "output_tokens" => 200,
               "duration_ms" => 1500,
               "success_rate" => 1.0
             } = totals

      assert {:ok, history} = Jobs.history(conn, "review")
      assert Enum.map(history, & &1["op"]) == ["create", "fire", "fire", "fire", "fire", "fire"]
    end

    test "two succeeded fires, one scheduled and one run now, are both counted", %{conn: conn} do
      {:ok, %{"fire_id" => a}} =
        Jobs.record_fire(conn, "review", %{
          "state" => "due",
          "scheduled_for" => "2026-01-01T00:00:00Z"
        })

      {:ok, %{"fire_id" => b}} =
        Jobs.record_fire(conn, "review", %{
          "state" => "due",
          "scheduled_for" => "2026-01-01T00:00:30Z",
          "manual" => true
        })

      for id <- [a, b], state <- ["running", "succeeded"] do
        {:ok, _} = Jobs.record_fire(conn, "review", %{"fire_id" => id, "state" => state})
      end

      assert {:ok, %{"fires" => %{"fires" => 2, "succeeded" => 2, "success_rate" => 1.0}}} =
               Jobs.get(conn, "review")
    end

    test "a fire's runs are priced by the config model, though the reply names the provider's id",
         %{conn: conn} do
      config =
        Fixtures.config("""
        [models.haiku]
        api = "openai-completions"
        url = "http://localhost:1/v1"
        timeout_ms = 1000
        model = "claude-haiku-5-5"
        price = { input = 1.0, output = 2.0, cache_write = 0.0, cache_read = 0.0 }

        [agents.front]
        depth = 0
        model = "haiku"
        text = "front"
        """)

      run = Fixtures.insert(conn, :runs, %{agent: "front"})

      for {extra, sequence} <- [{%{}, 901}, {%{"model_key" => "haiku"}, 902}] do
        body =
          Jason.encode!(
            Map.merge(
              %{
                "model" => "claude-haiku-5-5",
                "usage" => %{"input_tokens" => 1000, "output_tokens" => 500}
              },
              extra
            )
          )

        Fixtures.insert(conn, :events, %{
          type: "model",
          sequence: sequence,
          run_id: run,
          body: body
        })
      end

      assert {:ok, %{calls: 2, usd: usd}} = Jobs.Cost.of_runs(conn, config, [run])
      assert_in_delta usd, 2 * (1000 * 1.0 + 500 * 2.0) / 1.0e6, 1.0e-12
    end

    test "states follow their order and a slot is taken once", %{conn: conn} do
      due = %{"state" => "due", "scheduled_for" => "2026-01-01T00:00:00Z"}
      {:ok, %{"fire_id" => id}} = Jobs.record_fire(conn, "review", due)

      assert {:error, {:jobs, {:slot_taken, "2026-01-01T00:00:00Z"}}} =
               Jobs.record_fire(conn, "review", due)

      assert {:error, {:jobs, {:fire_state, "due", "succeeded"}}} =
               Jobs.record_fire(conn, "review", %{"fire_id" => id, "state" => "succeeded"})

      {:ok, _} = Jobs.record_fire(conn, "review", %{"fire_id" => id, "state" => "missed"})

      assert {:error, {:jobs, {:fire_state, "missed", "running"}}} =
               Jobs.record_fire(conn, "review", %{"fire_id" => id, "state" => "running"})

      assert {:error, {:jobs, {:unknown_fire, "nope"}}} =
               Jobs.record_fire(conn, "review", %{"fire_id" => "nope", "state" => "running"})

      assert {:error, {:jobs, {:invalid, "state"}}} =
               Jobs.record_fire(conn, "review", %{"state" => "exploded"})

      assert {:error, {:jobs, {:invalid, "usd"}}} =
               Jobs.record_fire(conn, "review", %{
                 "state" => "due",
                 "scheduled_for" => "2026-01-02T00:00:00Z",
                 "usd" => -1
               })

      assert {:error, {:jobs, {:invalid, "fire_id"}}} =
               Jobs.record_fire(conn, "review", %{"state" => "running"})

      assert {:error, {:jobs, {:invalid, "scheduled_for"}}} =
               Jobs.record_fire(conn, "review", %{"state" => "due"})
    end

    test "run is refused for an ended job", %{conn: conn, ctx: ctx} do
      {:ok, _} = Jobs.transition(conn, "review", "ended", "past its end date")
      assert {:state, "ended", "run"} = refused(conn, %{"op" => "run", "job" => "review"}, ctx)
    end
  end

  describe "due" do
    test "lists the slots after the job began or after its last claimed slot", %{conn: conn} do
      create(conn, ctx(config()))
      now = DateTime.utc_now()

      assert {:ok, []} = Jobs.due(conn, now)

      assert {:ok, [%{job: %{"name" => "review"}, slots: slots}]} =
               Jobs.due(conn, DateTime.add(now, 3 * 3600 + 60))

      [first, second, third] = Enum.to_list(slots)
      assert DateTime.diff(second, first) == 3600
      assert DateTime.diff(third, second) == 3600

      {:ok, _} =
        Jobs.record_fire(conn, "review", %{
          "state" => "due",
          "scheduled_for" => DateTime.to_iso8601(first)
        })

      assert {:ok, [%{slots: rest}]} = Jobs.due(conn, DateTime.add(now, 3 * 3600 + 60))
      assert Enum.to_list(rest) == [second, third]
    end

    test "leaves out paused jobs and slots past the end date", %{conn: conn} do
      ctx = ctx(config())
      ending = DateTime.add(DateTime.utc_now(), 90 * 60)
      create(conn, ctx, %{"end_at" => DateTime.to_iso8601(ending)})

      assert {:ok, [%{slots: slots}]} = Jobs.due(conn, DateTime.add(DateTime.utc_now(), 5 * 3600))
      assert length(Enum.to_list(slots)) == 1

      {:ok, _} = Jobs.transition(conn, "review", "paused", nil)
      assert {:ok, []} = Jobs.due(conn, DateTime.add(DateTime.utc_now(), 5 * 3600))
    end
  end

  describe "who may write" do
    @agent_ctx %{author: "agent", agent: "front", issuer: nil, subject: nil}

    test "an agent's create needs an approval, or the policy's leave", %{conn: conn} do
      ctx = ctx(config(), @agent_ctx)
      assert :approval_required = refused(conn, @review, ctx)

      open = String.replace(@jobs, "agent_may_create = false", "agent_may_create = true")
      ctx = ctx(config(open), @agent_ctx)
      assert {:ok, _} = write(conn, @review, ctx)

      assert {:ok,
              %{
                "owner" => %{"kind" => "agent", "agent" => "front"},
                "origin" => %{"author" => %{"agent" => "front"}, "channel" => "tool"}
              }} = Jobs.get(conn, "review")

      assert :owner_not_self =
               refused(conn, Map.merge(@review, %{"name" => "x", "owner" => "boss"}), ctx)

      assert :agent_creates_only =
               refused(conn, %{"op" => "transition", "job" => "review", "to" => "paused"}, ctx)
    end

    test "an approved proposal creates the job and names its request", %{conn: conn} do
      request = approved_request(conn, "approve")
      body = Map.put(@review, "request_id", request)

      assert {:ok, _} = write(conn, body, ctx(config()))

      assert {:ok, %{"origin" => %{"channel" => "proposal", "request_id" => ^request}}} =
               Jobs.get(conn, "review")

      assert {:ok, [%{request_id: ^request}]} =
               Query.all(conn, "SELECT request_id FROM events WHERE type = 'job'")
    end

    test "an agent may carry an approval but not a denial", %{conn: conn} do
      ctx = ctx(config(), @agent_ctx)

      assert {:ok, _} =
               write(conn, Map.put(@review, "request_id", approved_request(conn, "approve")), ctx)

      denied = approved_request(conn, "deny")

      assert {:not_approved, ^denied} =
               refused(conn, Map.merge(@review, %{"name" => "x", "request_id" => denied}), ctx)

      assert {:not_approved, "none"} =
               refused(conn, Map.merge(@review, %{"name" => "y", "request_id" => "none"}), ctx)
    end

    defp approved_request(conn, option) do
      options = %{"approve" => [%{"name" => "jobs", "args" => %{}}], "deny" => []}
      id = Fixtures.insert(conn, :requests, %{status: "closed", options: Jason.encode!(options)})

      Fixtures.insert(conn, :events, %{
        type: "reply",
        sequence: System.unique_integer([:positive]),
        request_id: id,
        body: Jason.encode!(%{"option" => option, "body" => "ok"})
      })

      id
    end
  end

  describe "runs a fire opened" do
    test "refuse jobs, and so do the runs below them", %{conn: conn} do
      ctx = ctx(config())
      fire_run = Fixtures.insert(conn, :runs, %{via: "job"})

      cause =
        Fixtures.insert(conn, :events, %{
          type: "comment",
          sequence: 1,
          run_id: fire_run
        })

      child = Fixtures.insert(conn, :runs, %{via: "delegate", cause_id: cause})
      other = Fixtures.insert(conn, :runs, %{via: "send"})

      assert :in_fire = refused(conn, @review, %{ctx | run_id: fire_run})
      assert :in_fire = refused(conn, @review, %{ctx | run_id: child})
      assert {:ok, _} = write(conn, @review, %{ctx | run_id: other})
    end
  end

  describe "delivery" do
    test "each finished fire with a reply is a message of the job's thread", %{conn: conn} do
      ctx = ctx(config())
      assert {:invalid, "delivery"} = refused(conn, Map.put(@review, "delivery", "sms"), ctx)
      create(conn, ctx, %{"name" => "quiet"})
      assert {:ok, []} = Jobs.messages(conn, "quiet")

      create(conn, ctx, %{"delivery" => "owner_inbox"})

      fire = fn slot, text ->
        {:ok, %{"fire_id" => id}} =
          Jobs.record_fire(conn, "review", %{"state" => "due", "scheduled_for" => slot})

        {:ok, _} =
          Jobs.record_fire(conn, "review", %{
            "fire_id" => id,
            "state" => "running",
            "conversation_id" => "c1"
          })

        {:ok, _} =
          Jobs.record_fire(conn, "review", %{
            "fire_id" => id,
            "state" => "succeeded",
            "message" => text
          })

        id
      end

      first = fire.("2026-01-01T00:00:00Z", "Monday news")
      fire.("2026-01-02T00:00:00Z", "Tuesday news")

      assert {:ok,
              [
                %{
                  "id" => ^first,
                  "text" => "Monday news",
                  "unread" => true,
                  "conversation_id" => "c1",
                  "sender" => %{"kind" => "job", "name" => "review"}
                },
                %{"text" => "Tuesday news"}
              ]} =
               Jobs.messages(conn, "review")

      assert {:ok, _} = write(conn, %{"op" => "read", "job" => "review"}, ctx)
      assert {:ok, [%{"unread" => false}, %{"unread" => false}]} = Jobs.messages(conn, "review")
      fire.("2026-01-03T00:00:00Z", "Wednesday news")
      assert {:ok, [_, _, %{"unread" => true}]} = Jobs.messages(conn, "review")
    end
  end

  describe "read" do
    test "totals and history belong to their job", %{conn: conn} do
      ctx = ctx(config())
      create(conn, ctx)
      create(conn, ctx, %{"name" => "other"})

      {:ok, %{"fire_id" => id}} =
        Jobs.record_fire(conn, "other", %{
          "state" => "due",
          "scheduled_for" => "2026-01-01T00:00:00Z"
        })

      {:ok, _} = Jobs.record_fire(conn, "other", %{"fire_id" => id, "state" => "running"})

      {:ok, _} =
        Jobs.record_fire(conn, "other", %{"fire_id" => id, "state" => "failed", "usd" => 1})

      assert {:ok,
              [
                %{"fires" => %{"fires" => 0}},
                %{"fires" => %{"failed" => 1, "usd" => 1.0, "success_rate" => +0.0}}
              ]} =
               Jobs.list(conn)

      assert {:ok, [%{"op" => "create"}]} = Jobs.history(conn, "review")
      assert {:ok, [%{"op" => "fire", "state" => "failed"}]} = Jobs.history(conn, "other", 1)
      assert {:error, {:jobs, {:unknown, "ghost"}}} = Jobs.history(conn, "ghost")
    end

    test "a store made before jobs keeps working: the events are the only change", %{conn: conn} do
      assert {:ok, []} = Jobs.list(conn)

      assert {:ok, indexes} =
               Query.all(
                 conn,
                 "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'events_job%'"
               )

      assert Enum.map(indexes, & &1.name) |> Enum.sort() == [
               "events_job_fire_ids",
               "events_job_fires",
               "events_jobs"
             ]
    end
  end
end
