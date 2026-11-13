defmodule Omunculus.ProcessFixtures do
  @moduledoc """
  A synthetic store for process mining: works of the `delivery` workflow
  (stages `to_do`, then `review`) that went through it in ways a miner must
  tell apart, written behind the store's back with a clock that moves as the
  scripts say. No model is called.

  A work's script is a list: `{:run, agent}` opens a run; `{:model, usd,
  seconds}`, `{:tool, name, seconds}`, `{:refused, name, seconds}` and
  `:end` are what the run's model did; `{:continue, from, to}`,
  `{:reopen, stage}` and `:cancel` are the work's moves.
  """

  alias Omunculus.{Fixtures, Id}
  alias Omunculus.Store.Query

  @base ~U[2026-03-01 10:00:00Z]

  @config """
  [agents.concierge]
  depth = 0
  text = "I keep the project."

  [agents.worker]
  depth = 1
  text = "I build."
  tools = ["read", "write", "bash"]
  deny = ["fs.write"]

  [agents.reviewer]
  depth = 1
  text = "I review."
  workflow_only = true

  [workflows.delivery]
  steps = [
    { name = "to_do", agent = "worker" },
    { name = "review", agent = "reviewer", deny = ["write"] },
  ]

  [store]
  path = "store.sqlite3"
  attachments = "files"
  attachment_bytes = 65536
  """

  @doc "The config of the delivery workflow, as TOML."
  def config, do: @config

  @doc """
  Seeds `conn` and returns `%{works: %{name => id}, conversations: [ids]}`.
  Two conversations: the first holds works that followed the workflow, one
  that was cancelled in its first stage and one that skipped a stage; the
  second, one that went back a stage after review, one reopened into its own
  stage and one that is still open.
  """
  def seed(conn) do
    Process.put(:process_clock, 0)
    Process.put(:process_sequence, 0)

    first = conversation(conn, 0)
    second = conversation(conn, 100)

    works = %{
      done_a: work(conn, first, "done", "review", done_script(0.5, true)),
      done_b: work(conn, first, "done", "review", done_script(0.25, true)),
      done_c: work(conn, first, "done", "review", done_script(0.25, true)),
      cancelled: work(conn, first, "cancelled", "to_do", cancelled_script()),
      skipped: work(conn, first, "done", "review", skipped_script()),
      back: work(conn, second, "done", "review", back_script()),
      repeated: work(conn, second, "open", "review", repeated_script()),
      open:
        work(conn, second, "open", "to_do", [
          {:run, "worker"},
          {:model, 0.1, 2},
          {:tool, "read", 1}
        ])
    }

    %{works: works, conversations: [first, second]}
  end

  defp done_script(usd, tested) do
    [
      {:run, "worker"},
      {:model, usd, 3},
      {:tool, "read", 1},
      {:tool, "read", 1},
      {:model, usd, 3},
      {:tool, "write", 2}
    ] ++
      if(tested, do: [{:tool, "bash", 4}], else: []) ++
      [{:tool, "continue", 1}, {:continue, "to_do", "review"}, :end] ++
      [
        {:run, "reviewer"},
        {:model, usd, 2},
        {:tool, "read", 1},
        {:tool, "continue", 1},
        {:continue, "review", nil},
        :end
      ]
  end

  defp cancelled_script do
    [
      {:run, "worker"},
      {:model, 1.0, 5},
      {:refused, "bash", 1},
      {:tool, "read", 1},
      {:tool, "write", 2},
      {:tool, "cancel", 1},
      :cancel
    ]
  end

  defp skipped_script do
    [{:run, "reviewer"}, {:model, 0.5, 2}, {:tool, "continue", 1}, {:continue, "review", nil}]
  end

  defp back_script do
    [
      {:run, "worker"},
      {:model, 0.5, 3},
      {:tool, "write", 2},
      {:tool, "bash", 4},
      {:tool, "continue", 1},
      {:continue, "to_do", "review"},
      {:run, "reviewer"},
      {:model, 0.5, 3},
      {:tool, "reopen", 1},
      {:reopen, "to_do"},
      {:run, "worker"},
      {:model, 0.5, 3},
      {:tool, "write", 2},
      {:tool, "bash", 4},
      {:tool, "continue", 1},
      {:continue, "to_do", "review"},
      {:run, "reviewer"},
      {:model, 0.5, 2},
      {:tool, "continue", 1},
      {:continue, "review", nil}
    ]
  end

  defp repeated_script do
    [
      {:run, "worker"},
      {:model, 0.5, 3},
      {:tool, "write", 2},
      {:reopen, "to_do"},
      {:tool, "write", 2},
      {:tool, "continue", 1},
      {:continue, "to_do", "review"}
    ]
  end

  defp conversation(conn, offset) do
    id = Id.new()
    at = time(offset)

    :ok =
      Query.insert(conn, :conversations, %{
        id: id,
        created_issuer: "local",
        created_subject: "owner",
        created_at: at
      })

    id
  end

  @doc """
  A work of `workflow` (nil for none) below `parent` (nil for a root) in
  `conversation`, with its script; returns its id.
  """
  def extra_work(conn, conversation, workflow, parent, script),
    do: work(conn, conversation, "done", nil, script, workflow, parent)

  defp work(conn, conversation, state, stage, script, workflow \\ "delivery", parent \\ nil) do
    id = Id.new()
    created = events_clock()

    :ok =
      Query.insert(conn, :works, %{
        id: id,
        conversation_id: conversation,
        title: "work #{id}",
        goal: "goal",
        workflow: workflow,
        parent_id: parent,
        stage: stage,
        assignee: "worker",
        state: state,
        created_at: created
      })

    event(conn, "work", %{conversation_id: conversation, work_id: id}, %{title: "t"})
    Enum.reduce(script, nil, &step(conn, conversation, id, &1, &2))
    id
  end

  defp step(conn, conversation, work, {:run, agent}, _run) do
    id = Id.new()

    :ok =
      Query.insert(conn, :runs, %{
        id: id,
        conversation_id: conversation,
        work_id: work,
        agent: agent,
        depth: "1",
        status: "done",
        origin_issuer: "local",
        origin_subject: "owner",
        started_at: events_clock(),
        finished_at: events_clock()
      })

    id
  end

  defp step(conn, conversation, work, {:model, usd, seconds}, run) do
    tick(seconds)

    reply = %{
      "model" => "synthetic-1",
      "content" => "thinking",
      "usage" => %{"input_tokens" => 100, "output_tokens" => 20, "cost" => usd}
    }

    event(conn, "model", ref(conversation, work, run), reply)
    run
  end

  defp step(conn, conversation, work, {:tool, name, seconds}, run),
    do: call(conn, conversation, work, run, name, true, seconds)

  defp step(conn, conversation, work, {:refused, name, seconds}, run),
    do: call(conn, conversation, work, run, name, false, seconds)

  defp step(conn, conversation, work, :end, run),
    do: call(conn, conversation, work, run, "end", true, 1)

  defp step(conn, conversation, work, {:continue, from, to}, run) do
    event(conn, "continue", ref(conversation, work, run), %{from: from, to: to})
    run
  end

  defp step(conn, conversation, work, {:reopen, stage}, run) do
    event(conn, "reopen", ref(conversation, work, run), %{stage: stage})
    run
  end

  defp step(conn, conversation, work, :cancel, run) do
    event(conn, "cancel", ref(conversation, work, run), %{body: "no"})
    run
  end

  defp call(conn, conversation, work, run, name, ok, seconds) do
    tick(seconds)

    event(conn, "tool", ref(conversation, work, run), %{
      name: name,
      args: %{},
      ok: ok,
      output: "out"
    })

    run
  end

  defp ref(conversation, work, run),
    do: %{conversation_id: conversation, work_id: work, run_id: run}

  defp event(conn, type, ref, body) do
    id = Id.new()

    :ok =
      Query.insert(
        conn,
        :events,
        Map.merge(ref, %{
          id: id,
          sequence: next_sequence(),
          type: type,
          body: Jason.encode!(body),
          at: events_clock()
        })
      )

    id
  end

  @doc "Adds a request raised, answered and an artifact written in `conversation`, by `run`."
  def traffic(conn, conversation, work, run) do
    request = Fixtures.insert(conn, :requests, %{work_id: work, run_id: run, status: "closed"})
    ref = %{conversation_id: conversation, work_id: work, run_id: run, request_id: request}
    opened = event(conn, "request", ref, %{reason: "may I"})
    :ok = Query.exec(conn, "UPDATE requests SET event_id = ? WHERE id = ?", [opened, request])
    event(conn, "reply", ref, %{body: "yes"})

    event(conn, "artifact", %{conversation_id: conversation, run_id: run, work_id: work}, %{
      name: "plan.md",
      kind: "plan",
      version: 1
    })

    request
  end

  defp tick(seconds), do: Process.put(:process_clock, Process.get(:process_clock) + seconds)
  defp events_clock, do: time(Process.get(:process_clock))
  defp time(offset), do: @base |> DateTime.add(offset, :second) |> DateTime.to_iso8601()

  defp next_sequence do
    Process.put(:process_sequence, Process.get(:process_sequence) + 1)
  end
end
