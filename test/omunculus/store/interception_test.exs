defmodule Omunculus.Store.InterceptionTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.{Attachments, Fixtures, Id, Participant, Store}
  alias Omunculus.Store.{Query, View}

  @config """
  [agents.root]
  depth = 0
  text = "root"
  tools = ["reply", "ask", "end", "grant", "comment", "attach"]
  [agents.worker]
  depth = 1
  text = "worker"
  tools = ["ask", "end", "comment", "attach"]
  [accounts]
  owner = { kind = "human", issuer = "test", subject = "owner" }
  boss = { kind = "human", issuer = "test", subject = "boss" }
  """

  setup %{conn: conn} do
    conversation = Id.new()

    :ok =
      Query.insert(conn, :conversations, %{
        id: conversation,
        created_issuer: "test",
        created_subject: "client",
        created_at: "2026-01-01"
      })

    root =
      Fixtures.insert(conn, :works, %{
        assignee: "root",
        conversation_id: conversation
      })

    child =
      Fixtures.insert(conn, :works, %{
        assignee: "worker",
        parent_id: root,
        conversation_id: conversation
      })

    %{conversation: conversation, root: root, child: child}
  end

  defp config(rules), do: Fixtures.config(@config <> rules)

  defp agent_ctx(conn, config, ctx, agent, work) do
    run =
      Fixtures.open_run(conn, %{
        agent: agent,
        depth: if(agent == "root", do: 0, else: 1),
        work_id: work,
        conversation_id: ctx.conversation,
        ceiling: %{
          have: ["ask", "reply", "end", "grant", "comment", "attach"],
          askable: ["write"],
          sealed: [],
          blocked: [],
          uncited: "askable",
          overrides: %{}
        }
      })

    %{
      run_id: run.id,
      work_id: work,
      author: "agent",
      agent: agent,
      config: config,
      groups: %{},
      conversation_id: ctx.conversation
    }
  end

  defp human(config, ctx, subject),
    do: %{
      run_id: nil,
      work_id: nil,
      author: "human",
      agent: nil,
      issuer: "test",
      subject: subject,
      config: config,
      groups: %{},
      conversation_id: ctx.conversation
    }

  defp act(conn, type, body, ctx) do
    call = %{name: type, args: body, ok: true, output: ""}
    Store.record_tools(conn, ctx.run_id, [{call, [%{"type" => type, "body" => body}]}], ctx)
  end

  defp review_of(events), do: Enum.find(events, &(&1.type == "request"))

  defp request(conn, id) do
    {:ok, request} = View.view(conn, "request", id)
    request
  end

  defp work(conn, id) do
    {:ok, work} = View.view(conn, "work", id)
    work
  end

  defp rows(conn, sql, params \\ []) do
    {:ok, rows} = Query.all(conn, sql, params)
    rows
  end

  defp ask_review(conn, ctx, rules, reason \\ "Can we ship on Friday?") do
    config = config(rules)
    root = agent_ctx(conn, config, ctx, "root", ctx.root)
    assert {:ok, events} = act(conn, "request", %{"reason" => reason, "options" => %{}}, root)
    {config, root, review_of(events)}
  end

  @ask_owner """
  [[interceptors]]
  action = "ask"
  to = "requester"
  accounts = ["owner"]
  """

  test "an ask to the requester becomes a review request to the first reviewer",
       %{conn: conn} = ctx do
    {_config, _root, review} = ask_review(conn, ctx, @ask_owner)
    request = request(conn, review.request_id)

    assert Jason.decode!(request.arbiter) == Participant.human("test", "owner")
    assert Jason.decode!(request.requester) == Participant.agent("root")
    assert request.reason =~ ~s(root would ask test:client: "Can we ship on Friday?")

    assert request.options |> Jason.decode!() |> Map.keys() |> Enum.sort() ==
             ~w(approve deny edit)

    assert request.interception.action == "ask"
    assert request.interception.step == 0
    assert request.interception.reviewers == ["owner"]

    assert %{state: "waiting", waiting: "request", waiting_for: id} = work(conn, ctx.root)
    assert id == review.request_id
    assert [_only] = rows(conn, "SELECT id FROM requests")
  end

  test "approve performs the ask as the actor, released by the review", %{conn: conn} = ctx do
    {config, _root, review} = ask_review(conn, ctx, @ask_owner)
    owner = human(config, ctx, "owner")

    assert {:ok, events} =
             act(
               conn,
               "reply",
               %{"request_id" => review.request_id, "option" => "approve", "body" => "Go."},
               owner
             )

    assert Enum.map(events, & &1.type) == ~w(tool reply release request)
    performed = Enum.find(events, &(&1.type == "request"))
    asked = request(conn, performed.request_id)

    assert Jason.decode!(asked.arbiter) == Participant.human("test", "client")
    assert Jason.decode!(asked.requester) == Participant.agent("root")
    assert asked.reason == "Can we ship on Friday?"
    assert performed.actor_kind == "agent" and performed.actor_id == "root"
    assert performed.released_by == review.request_id
    assert Enum.find(events, &(&1.type == "reply")).released_by == nil
    assert %{status: "closed"} = request(conn, review.request_id)
    assert work(conn, ctx.root).waiting_for == performed.request_id
  end

  test "edit performs the ask with the reviewer's reply as its reason", %{conn: conn} = ctx do
    {config, _root, review} = ask_review(conn, ctx, @ask_owner)

    assert {:ok, events} =
             act(
               conn,
               "reply",
               %{"request_id" => review.request_id, "option" => "edit", "body" => "Ship Monday?"},
               human(config, ctx, "owner")
             )

    assert request(conn, review_of(events).request_id).reason == "Ship Monday?"
  end

  test "deny answers the actor and performs nothing", %{conn: conn} = ctx do
    {config, _root, review} = ask_review(conn, ctx, @ask_owner)

    assert {:ok, events} =
             act(
               conn,
               "reply",
               %{"request_id" => review.request_id, "option" => "deny", "body" => "Not now."},
               human(config, ctx, "owner")
             )

    assert Enum.map(events, & &1.type) == ~w(tool reply)
    assert [_only] = rows(conn, "SELECT id FROM requests")
    assert %{state: "open", waiting_for: nil} = work(conn, ctx.root)

    assert [%{body: "Not now."}] =
             rows(conn, "SELECT body FROM comments WHERE request_id = ? AND author = 'human'", [
               review.request_id
             ])

    assert request(conn, review.request_id).answer == "deny"
  end

  test "a review reply names approve, edit or deny", %{conn: conn} = ctx do
    {config, _root, review} = ask_review(conn, ctx, @ask_owner)

    assert {:error, {:reply, :review_option}} =
             act(
               conn,
               "reply",
               %{"request_id" => review.request_id, "body" => "Fine."},
               human(config, ctx, "owner")
             )

    assert {:error, {:reply, {:unknown_option, "maybe", _}}} =
             act(
               conn,
               "reply",
               %{"request_id" => review.request_id, "option" => "maybe", "body" => "?"},
               human(config, ctx, "owner")
             )
  end

  @two """
  [[interceptors]]
  action = "ask"
  accounts = ["owner", "boss"]
  """

  test "reviewers answer in order, the next seeing the previous edit", %{conn: conn} = ctx do
    {config, _root, first} = ask_review(conn, ctx, @two)

    assert {:ok, events} =
             act(
               conn,
               "reply",
               %{"request_id" => first.request_id, "option" => "edit", "body" => "Ship Monday?"},
               human(config, ctx, "owner")
             )

    assert Enum.map(events, & &1.type) == ~w(tool reply request)
    second = review_of(events)
    next = request(conn, second.request_id)

    assert Jason.decode!(next.arbiter) == Participant.human("test", "boss")
    assert Jason.decode!(next.requester) == Participant.agent("root")
    assert next.reason =~ ~s(ask test:client: "Ship Monday?")
    assert next.interception.step == 1
    assert request(conn, first.request_id).interception.next_id == second.request_id
    assert work(conn, ctx.root).waiting_for == second.request_id

    assert {:ok, events} =
             act(
               conn,
               "reply",
               %{"request_id" => second.request_id, "option" => "approve", "body" => "Yes."},
               human(config, ctx, "boss")
             )

    asked = request(conn, Enum.find(events, &(&1.type == "request")).request_id)
    assert asked.reason == "Ship Monday?"
    assert Jason.decode!(asked.arbiter) == Participant.human("test", "client")
  end

  test "a deny at any reviewer stops the action", %{conn: conn} = ctx do
    {config, _root, first} = ask_review(conn, ctx, @two)

    {:ok, events} =
      act(
        conn,
        "reply",
        %{"request_id" => first.request_id, "option" => "approve", "body" => "Ok."},
        human(config, ctx, "owner")
      )

    second = review_of(events)

    assert {:ok, events} =
             act(
               conn,
               "reply",
               %{"request_id" => second.request_id, "option" => "deny", "body" => "No."},
               human(config, ctx, "boss")
             )

    assert Enum.map(events, & &1.type) == ~w(tool reply)
    assert [_first, _second] = rows(conn, "SELECT id FROM requests")
    assert %{state: "open"} = work(conn, ctx.root)
  end

  test "a released action is held again only by another rule", %{conn: conn} = ctx do
    rules = """
    [[interceptors]]
    action = "ask"
    accounts = ["owner"]
    [[interceptors]]
    action = "ask"
    accounts = ["boss"]
    """

    {config, _root, first} = ask_review(conn, ctx, rules)
    assert Jason.decode!(request(conn, first.request_id).arbiter)["subject"] == "owner"

    {:ok, events} =
      act(
        conn,
        "reply",
        %{"request_id" => first.request_id, "option" => "approve", "body" => "Ok."},
        human(config, ctx, "owner")
      )

    second = request(conn, review_of(events).request_id)
    assert Jason.decode!(second.arbiter)["subject"] == "boss"
    assert second.interception.rule == 1
    assert second.interception.passed == [0]
    assert second.interception.step == 0

    {:ok, events} =
      act(
        conn,
        "reply",
        %{"request_id" => second.id, "option" => "approve", "body" => "Ok."},
        human(config, ctx, "boss")
      )

    final = request(conn, Enum.find(events, &(&1.type == "request")).request_id)
    assert final.interception == nil
    assert Jason.decode!(final.arbiter)["subject"] == "client"
  end

  test "a comment on the root work is held for to = requester, one below is not",
       %{conn: conn} = ctx do
    config =
      config("""
      [[interceptors]]
      action = "comment"
      to = "requester"
      accounts = ["owner"]
      """)

    root = agent_ctx(conn, config, ctx, "root", ctx.root)
    worker = agent_ctx(conn, config, ctx, "worker", ctx.child)

    assert {:ok, events} =
             act(conn, "comment", %{"body" => "Done.", "work_id" => ctx.child}, worker)

    assert Enum.map(events, & &1.type) == ~w(tool comment)

    assert {:ok, events} =
             act(conn, "comment", %{"body" => "All shipped.", "work_id" => ctx.root}, root)

    assert Enum.map(events, & &1.type) == ~w(tool request)
    review = request(conn, review_of(events).request_id)
    assert review.interception.action == "comment"
    assert review.reason =~ ~s(comment for test:client: "All shipped.")

    refute rows(conn, "SELECT id FROM comments WHERE body = 'All shipped.' AND author = 'agent'") !=
             []

    assert {:ok, events} =
             act(
               conn,
               "reply",
               %{"request_id" => review.id, "option" => "edit", "body" => "Shipped, with notes."},
               human(config, ctx, "owner")
             )

    comment = Enum.find(events, &(&1.type == "comment"))
    assert comment.released_by == review.id
    assert comment.actor_id == "root"

    assert [%{body: "Shipped, with notes."}] =
             rows(conn, "SELECT body FROM comments WHERE id = ?", [comment.comment_id])
  end

  test "an attachment is held and released with the reviewer's note", %{conn: conn} = ctx do
    config =
      config("""
      [[interceptors]]
      action = "attach"
      accounts = ["owner"]
      [store]
      path = "s.sqlite3"
      attachments = "files"
      attachment_bytes = 64
      """)

    {:ok, meta} = Attachments.put(config.store, "plan.txt", "text/plain", "the plan")
    root = agent_ctx(conn, config, ctx, "root", ctx.root)

    assert {:ok, events} =
             act(conn, "attach", %{"attachments" => [meta], "note" => "Plan"}, root)

    assert Enum.map(events, & &1.type) == ~w(tool request)
    review = request(conn, review_of(events).request_id)
    assert review.interception.action == "attach"
    assert review.reason =~ ~s(attach plan.txt: "Plan")
    assert rows(conn, "SELECT id FROM events WHERE type = 'attach'") == []

    assert {:ok, events} =
             act(
               conn,
               "reply",
               %{"request_id" => review.id, "option" => "edit", "body" => "Plan v2"},
               human(config, ctx, "owner")
             )

    attach = Enum.find(events, &(&1.type == "attach"))
    assert attach.released_by == review.id
    assert Jason.decode!(attach.body)["note"] == "Plan v2"
  end

  test "a grant of an agent is held and released", %{conn: conn} = ctx do
    config =
      config("""
      [[interceptors]]
      action = "grant"
      accounts = ["owner"]
      """)

    worker = agent_ctx(conn, config, ctx, "worker", ctx.child)
    root = agent_ctx(conn, config, ctx, "root", ctx.root)
    grant = %{"name" => "grant", "args" => %{"name" => "write", "kind" => "tool"}}

    {:ok, events} =
      act(
        conn,
        "request",
        %{"reason" => "May I write?", "options" => %{"allow" => [grant]}},
        worker
      )

    asked = review_of(events).request_id

    {:ok, _events} =
      act(conn, "reply", %{"request_id" => asked, "option" => "allow", "body" => "Yes."}, root)

    assert {:ok, events} =
             act(
               conn,
               "grant",
               %{"request_id" => asked, "name" => "write", "kind" => "tool"},
               root
             )

    assert Enum.map(events, & &1.type) == ~w(tool request)
    review = request(conn, review_of(events).request_id)
    assert review.interception.action == "grant"
    assert review.reason =~ "grant write (tool) to worker"
    assert work(conn, ctx.child).grants == nil

    assert {:ok, events} =
             act(
               conn,
               "reply",
               %{"request_id" => review.id, "option" => "approve", "body" => "Ok."},
               human(config, ctx, "owner")
             )

    granted = Enum.find(events, &(&1.type == "grant"))
    assert granted.released_by == review.id
    assert work(conn, ctx.child).grants == ~s(["write"])
  end

  test "an agent reviews like a person: its inbox holds the review and its reply releases",
       %{conn: conn} = ctx do
    config =
      config("""
      [[interceptors]]
      action = "comment"
      agent = "worker"
      accounts = ["root"]
      """)

    worker = agent_ctx(conn, config, ctx, "worker", ctx.child)
    root = agent_ctx(conn, config, ctx, "root", ctx.root)

    assert {:ok, events} =
             act(conn, "comment", %{"body" => "Half done.", "work_id" => ctx.child}, worker)

    review = request(conn, review_of(events).request_id)
    assert Jason.decode!(review.arbiter) == Participant.agent("root")
    assert %{state: "waiting", waiting: "request"} = work(conn, ctx.child)

    assert {:ok, events} =
             act(
               conn,
               "reply",
               %{"request_id" => review.id, "option" => "approve", "body" => "Fine."},
               root
             )

    comment = Enum.find(events, &(&1.type == "comment"))
    assert comment.released_by == review.id
    assert comment.actor_id == "worker"
    assert comment.work_id == ctx.child
    assert %{state: "open"} = work(conn, ctx.child)
  end

  test "an agent never reviews its own action", %{conn: conn} = ctx do
    config =
      config("""
      [[interceptors]]
      action = "comment"
      accounts = ["root"]
      """)

    root = agent_ctx(conn, config, ctx, "root", ctx.root)
    assert {:ok, events} = act(conn, "comment", %{"body" => "Mine.", "work_id" => ctx.root}, root)
    assert Enum.map(events, & &1.type) == ~w(tool comment)
  end

  test "a person's action is never held", %{conn: conn} = ctx do
    config = config(@ask_owner)

    assert {:ok, events} =
             act(
               conn,
               "comment",
               %{"body" => "Hi.", "work_id" => ctx.root},
               human(config, ctx, "client")
             )

    assert Enum.map(events, & &1.type) == ~w(tool comment)
  end
end
