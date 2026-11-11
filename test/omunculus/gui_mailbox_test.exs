defmodule Omunculus.GuiMailboxTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const me = {issuer: "local", subject: "1000"};
  const human = {kind: "human", issuer: "local", subject: "1000"};
  const agent = name => ({kind: "agent", agent: name});
  const prompt = (cursor, at, message, to) => ({type: "prompt", cursor, at, actor: human, body: {message, agent: to || "sales"}});
  const run = (id, who, status, depth) => ({id, agent: who, depth: depth === undefined ? 0 : depth, status, started_at: "2026-01-01T10:00:00Z", finished_at: status === "open" ? null : "2026-01-01T10:05:00Z"});
  const model = (cursor, at, run_id, text) => ({type: "model", cursor, at, run_id, body: {content: text}});
  const request = (id, over) => Object.assign({id, status: "pending", requester: agent("sales"), arbiter: human, reason: "Which pages?", origins: {}, options: {}, created_at: "2026-01-01T10:02:00Z"}, over || {});
  const snap = over => Object.assign({conversation: {created_at: "2026-01-01T09:00:00Z"}, works: [], runs: [], requests: []}, over || {});
  const build = (snapshot, events) => Mailbox.build("agency", "c1", snapshot, events, me);
  """

  defp run!(assertions) do
    assert {"", 0} = GuiModules.run(["Requests", "Model", "Mailbox"], @fixtures <> assertions)
  end

  test "the client scripts avoid String.trimEnd, which the QML engine lacks" do
    for file <- Path.wildcard("apps/kit/client/*.js") ++ Path.wildcard("apps/*/*.{js,qml}") do
      refute File.read!(file) =~ ~r/\.trim(End|Start)\(/, file
    end
  end

  test "addresses, names and autocomplete" do
    run!("""
    const p = Mailbox.person("sales", "agency");
    if (p.text !== "Sales <sales@agency>") throw Error(p.text);
    if (Mailbox.person("language_lawyer", "x").name !== "Language lawyer") throw Error("name");
    const roster = [{name: "sales", depth: 0}, {name: "seller", depth: 1}, {name: "flow", depth: 0, workflow_only: true}];
    if (Mailbox.chat(roster).join() !== "sales") throw Error("only depth 0 and not workflow-only");
    const list = Mailbox.recipients([{id: "agency", agents: ["sales", "steward"]}, {id: "dev", agents: ["sales"]}]);
    if (list.length !== 3) throw Error("across projects");
    if (Mailbox.suggest(list, "ste").map(x => x.address).join() !== "steward@agency") throw Error("suggest by name");
    if (Mailbox.suggest(list, "@dev").map(x => x.address).join() !== "sales@dev") throw Error("suggest by address");
    if (Mailbox.suggest(list, "").length !== 3) throw Error("empty query lists all");
    if (Mailbox.suggest(list, "SALES").length !== 2) throw Error("case aside, by name");
    const places = [
      {id: "dev", agents: ["a", "b"], defaultAgent: ""},
      {id: "agency", agents: ["auditor", "sales", "steward"], defaultAgent: "sales"},
      {id: "locked", agents: ["x"], defaultAgent: "", canWrite: false}
    ];
    const order = Mailbox.recipients(places, "agency").map(x => x.address).join();
    if (order !== "sales@agency,auditor@agency,steward@agency,a@dev,b@dev") throw Error(order);
    if (Mailbox.recipients(places, "")[0].address !== "a@dev") throw Error("no current project keeps registry order");
    if (!Mailbox.canWrite(["conversation.create", "conversation.send"]) || Mailbox.canWrite(["conversation.send"]) || Mailbox.canWrite([])) throw Error("capabilities");
    """)
  end

  test "the default agent comes from the whole config and must be one to write to" do
    run!("""
    const roster = [{name: "sales", depth: 0}, {name: "seller", depth: 1}];
    const setup = name => ({agents: roster, default_agent: name === undefined ? null : name});
    if (Mailbox.defaultAgent(setup("sales")) !== "sales") throw Error("declared");
    if (Mailbox.defaultAgent(setup()) !== "") throw Error("absent");
    if (Mailbox.defaultAgent(setup("seller")) !== "") throw Error("not depth 0");
    if (Mailbox.defaultAgent({agents: roster}) !== "") throw Error("missing key");
    """)
  end

  test "a thread is the person's messages, the agent's words and its requests for the person" do
    run!("""
    const events = [
      prompt("1", "2026-01-01T10:00:00Z", "Website\\n\\nI need a site."),
      model("2", "2026-01-01T10:01:00Z", "r1", "Thanks, one question coming."),
      {type: "model", cursor: "3", at: "2026-01-01T10:01:30Z", run_id: "r1", body: {content: [{type: "text", text: "I will ask now"}, {type: "tool_use", name: "ask", input: {}}]}},
      model("4", "2026-01-01T10:01:40Z", "r2", "I am the seller talking to myself"),
      {type: "reply", cursor: "5", at: "2026-01-01T10:03:00Z", request_id: "q1", actor: human, body: {body: "Home and Menu"}}
    ];
    const snapshot = snap({
      runs: [run("r1", "sales", "closed"), run("r2", "seller", "closed", 1)],
      requests: [
        request("q1", {status: "closed"}),
        request("q2", {created_at: "2026-01-01T10:04:00Z", reason: "Which colour?"}),
        request("q3", {requester: agent("seller"), reason: "owner approval"}),
        request("q4", {arbiter: agent("sales")})
      ]
    });
    const t = build(snapshot, events);
    if (t.agent !== "sales" || t.with.text !== "Sales <sales@agency>") throw Error("agent");
    if (t.subject !== "Website") throw Error("subject " + t.subject);
    const shown = t.messages.map(m => (m.mine ? "me:" : "sales:") + m.text);
    const want = ["me:I need a site.", "sales:Thanks, one question coming.", "sales:Which pages?", "me:Home and Menu", "sales:Which colour?"];
    if (JSON.stringify(shown) !== JSON.stringify(want)) throw Error(JSON.stringify(shown));
    if (t.pending.join() !== "q2") throw Error("pending " + t.pending);
    if (t.messages.some(m => m.text.includes("seller") || m.text.includes("owner"))) throw Error("another agent leaked");
    if (t.received !== 3 || t.sent !== 2) throw Error("counts");
    if (t.parties !== "Sales, me (5)") throw Error(t.parties);
    if (t.at !== "2026-01-01T10:04:00Z" || t.heard !== "2026-01-01T10:04:00Z") throw Error("times");
    """)
  end

  test "a request's e-mail is only the thread agent's reason, never its origins' questions" do
    run!("""
    const origins = {seller: {reason: "The status is sent, awaiting you"}, price: {reason: "Which pages?"}};
    const t = build(snap({requests: [request("q1", {origins})]}), [prompt("1", "2026-01-01T10:00:00Z", "Hi")]);
    const text = t.messages.find(m => m.request === "q1").text;
    if (text !== "Which pages?") throw Error(JSON.stringify(text));
    const longer = build(snap({requests: [request("q1", {reason: "Proposal ready.", origins: {a: {reason: "Proposal ready. Status is sent."}}})]}), [prompt("1", "2026-01-01T10:00:00Z", "Hi")]);
    if (longer.messages.find(m => m.request === "q1").text !== "Proposal ready.") throw Error("an origin's text is not the body");
    """)
  end

  test "harness notes stay hidden and passed-on questions show as the agent's" do
    run!("""
    const harness = id => ({type: "request", cursor: "h" + id, at: "2026-01-01T10:02:00Z", request_id: id, actor: {kind: "harness"}, body: {}});
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Hi"), harness("n1"), harness("n2")];
    const snapshot = snap({requests: [
      request("n1", {requester: agent("seller"), reason: "left unanswered", origins: {}}),
      request("n2", {requester: agent("seller"), reason: "it came to you", origins: {ask: {reason: "What is the budget?"}}})
    ]});
    const t = build(snapshot, events);
    if (t.messages.some(m => m.request === "n1")) throw Error("a note between agents is no e-mail");
    if (t.pending.join() !== "n2") throw Error("pending " + t.pending);
    const text = t.messages.find(m => m.request === "n2").text;
    if (text !== "What is the budget?") throw Error(text);
    """)
  end

  test "the first message splits into subject and body" do
    run!("""
    const s = Mailbox.split("Menu photos\\n\\nWhich ones?");
    if (s.subject !== "Menu photos" || s.body !== "Which ones?") throw Error("split");
    const one = Mailbox.split("I accept.");
    if (one.subject !== "I accept." || one.body !== "I accept.") throw Error("one line is its own body");
    const long = Mailbox.split("x".repeat(120) + "\\nrest");
    if (long.subject.length !== 90 || !long.body.startsWith("xxx")) throw Error("long first line");
    if (Mailbox.re("Menu") !== "Re: Menu" || Mailbox.re("re: Menu") !== "re: Menu") throw Error("re");
    if (Mailbox.fwd("Menu") !== "Fwd: Menu") throw Error("fwd");
    const q = Mailbox.quoted({from: {name: "Sales"}, text: "a\\n\\nb"}, "10 Nov 2026, 18:02");
    if (q.head !== "On 10 Nov 2026, 18:02, Sales wrote:" || q.lines.join("|") !== "> a|>|> b") throw Error(JSON.stringify(q));
    const w = Mailbox.quoted({from: {name: "Sales"}, text: "a  \\nb\\t"}, "x");
    if (w.lines.join("|") !== "> a|> b") throw Error("trailing blanks: " + JSON.stringify(w));
    """)
  end

  test "owner decisions never reach the mailbox, and only they pending read as in progress" do
    run!("""
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Hi")];
    const works = [{id: "w1", state: "waiting", waiting: "request", parent_id: null}];
    const closed = [run("r1", "sales", "closed")];
    const mails = (requests) => build(snap({runs: closed, works, requests}), events);
    const shown = mails([request("c", {route: null, destination: "origin"}), request("o1", {route: "boss", destination: "owners"}), request("o2", {destination: "owners"}), request("bare")]);
    if (shown.pending.join() !== "c,bare") throw Error("pending " + shown.pending);
    if (shown.messages.some(message => message.request.startsWith("o"))) throw Error("an owner decision is no e-mail");
    const hidden = mails([request("o1", {route: "boss", destination: "owners"})]);
    if (hidden.pending.length !== 0 || hidden.label !== "progress") throw Error("only hidden requests: " + hidden.label);
    """)
  end

  test "labels: in progress, stuck, cancelled, or none" do
    run!("""
    const at = "2026-01-01T10:00:00Z";
    const events = [prompt("1", at, "Hi")];
    const label = (over, ev) => build(snap(over), ev || events).label;
    const work = (state, waiting, parent) => ({id: "w" + Math.random(), state, waiting: waiting || null, parent_id: parent || null});
    if (label({runs: [run("r1", "sales", "open")], works: [work("open")]}) !== "progress") throw Error("run open");
    if (label({runs: [run("r1", "sales", "open", 2)]}) !== "progress") throw Error("any depth");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("waiting", "child"), work("open", null, "x")]}) !== "progress") throw Error("work waits on children");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("open")], requests: [request("q9", {arbiter: agent("sales"), requester: agent("seller")})]}) !== "progress") throw Error("waits on someone else");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("open")]}) !== "stuck") throw Error("stalled");
    const failed = [prompt("1", at, "Hi"), {type: "end-run", cursor: "9", at, run_id: "r1", body: {error: "boom"}}];
    if (label({runs: [run("r1", "sales", "closed")], works: [work("done")]}, failed) !== "stuck") throw Error("failed");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("cancelled"), work("cancelled")]}) !== "cancelled") throw Error("cancelled");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("done")]}) !== "") throw Error("done has no label");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("open")], requests: [request("q1")]}) !== "") throw Error("waiting for the client is no label");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("waiting", "message")]}) !== "") throw Error("waiting for the client's word is no label");
    if (Mailbox.labels.stuck !== "Stuck") throw Error("words");
    """)
  end

  test "a reply answers the request of the e-mail it replies to, else the newest, else messages the agent" do
    run!("""
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Hi"), model("2", "2026-01-01T10:01:00Z", "r1", "Hello")];
    const two = build(snap({runs: [run("r1", "sales", "closed")], requests: [
      request("q1", {created_at: "2026-01-01T10:02:00Z", reason: "First?"}),
      request("q2", {created_at: "2026-01-01T10:03:00Z", reason: "Second?"})
    ]}), events);
    if (two.pending.join() !== "q1,q2") throw Error("pending order");
    let t = Mailbox.replyTarget(two, "q1");
    if (t.request !== "q1" || t.quoted.text !== "First?") throw Error("replying to a request answers it");
    t = Mailbox.replyTarget(two, "r1");
    if (t.request !== "q2" || t.quoted.text !== "Second?") throw Error("an ordinary e-mail answers the newest pending request, and quotes it");
    const none = build(snap({runs: [run("r1", "sales", "closed")]}), events);
    t = Mailbox.replyTarget(none, "r1");
    if (t.request !== "" || t.quoted.text !== "Hello") throw Error("no request: a message to the agent");
    if (JSON.stringify(Mailbox.answer("  yes ")) !== JSON.stringify({body: "yes"})) throw Error("text only");
    const closed = build(snap({runs: [run("r1", "sales", "closed")], requests: [request("q1", {status: "closed"})]}), events);
    if (Mailbox.replyTarget(closed, "q1").request !== "") throw Error("a closed request is not answered");
    """)
  end

  test "folders, archive, unread, search and forward" do
    run!("""
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Hi\\n\\nabout the menu"), model("2", "2026-01-01T10:01:00Z", "r1", "Hello")];
    const t = build(snap({runs: [run("r1", "sales", "closed")]}), events);
    const lone = build(snap(), [events[0]]);
    const none = {};
    if (!Mailbox.inFolder(t, "inbox", none) || !Mailbox.inFolder(t, "sent", none)) throw Error("both");
    if (Mailbox.inFolder(lone, "inbox", none) || !Mailbox.inFolder(lone, "sent", none)) throw Error("unanswered is only sent");
    const archived = {[t.key]: "2026-01-01T11:00:00Z"};
    if (Mailbox.inFolder(t, "inbox", archived) || !Mailbox.inFolder(t, "archive", archived)) throw Error("archived");
    const later = {[t.key]: "2026-01-01T10:00:30Z"};
    if (!Mailbox.inFolder(t, "inbox", later) || Mailbox.inFolder(t, "archive", later)) throw Error("new mail unarchives");
    if (Mailbox.inFolder(t, "drafts", none)) throw Error("drafts hold no threads");
    if (!Mailbox.isUnread(t, none) || Mailbox.isUnread(t, {[t.key]: t.heard}) || Mailbox.isUnread(lone, none)) throw Error("unread");
    if (!Mailbox.matches(t, "MENU") || !Mailbox.matches(t, "agency") || Mailbox.matches(t, "zzz")) throw Error("search");
    const f = Mailbox.forward(t, t.messages[1]);
    if (f.subject !== "Fwd: Hi" || !f.body.includes("From: Sales <sales@agency>") || !f.body.endsWith("Hello")) throw Error(f.body);
    """)
  end
end
