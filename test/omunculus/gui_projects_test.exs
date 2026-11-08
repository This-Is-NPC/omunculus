defmodule Omunculus.GuiProjectsTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const place = id => ({id, socket: "/run/" + id + ".sock"});
  const conversation = (id, created_at) => ({id, created_at});
  const work = (state, updated_at) => ({state, updated_at});
  const input = fields => Object.assign({
    projects: [], conversations: {}, works: {}, summaries: {}, unreachable: new Set(), current: ""
  }, fields);
  const byId = rows => Object.fromEntries(rows.map(row => [row.id, row]));
  const check = (ok, what) => { if (!ok) throw Error(what); };
  """

  defp run!(assertions) do
    assert {"", 0} =
             GuiModules.run(["Requests", "Questions", "Projects"], @fixtures <> assertions)
  end

  test "rows count conversations and the latest activity" do
    run!("""
    const rows = Projects.rows(input({
      projects: [place("agency")],
      conversations: {agency: [conversation("c1", "2026-11-03T10:00:00Z"), conversation("c2", "2026-11-03T12:00:00Z")]},
      works: {agency: [work("open", "2026-11-03T13:00:00Z"), work("done", "2026-11-03T09:00:00Z"), work("cancelled", "2026-11-03T08:00:00Z"), work("broken", "2026-11-03T11:00:00Z")]},
      summaries: {c1: {started: true, running: 1, waiting: 0}, c2: {started: true, running: 0, waiting: 0}},
      current: "agency"
    }));
    const row = rows[0];
    check(row.id === "agency" && row.socket === "/run/agency.sock", "place");
    check(row.current && row.reachable, "current " + JSON.stringify(row));
    check(row.conversations === 2, "counts " + JSON.stringify(row));
    check(row.last === "2026-11-03T13:00:00Z", "last " + row.last);
    check(row.working === 1 && row.needsYou === 0 && row.state === "working", "state " + row.state);
    """)
  end

  test "rows count conversations by the state the conversations page shows" do
    run!("""
    const c = id => conversation(id, "2026-11-03T10:00:00Z");
    const row = Projects.rows(input({
      projects: [place("agency")],
      conversations: {agency: [c("asks"), c("asks-too"), c("both"), c("runs"), c("fresh"), c("unread")]},
      summaries: {
        asks: {started: true, running: 0, waiting: 3},
        "asks-too": {started: true, running: 0, waiting: 1},
        both: {started: true, running: 2, waiting: 1},
        runs: {started: true, running: 2, waiting: 0},
        fresh: {started: false, running: 0, waiting: 0},
        unread: {started: true, running: 0, waiting: 0}
      }
    }))[0];
    check(row.needsYou === 3 && row.working === 1, "one count per conversation " + JSON.stringify(row));
    check(row.conversations === 6 && row.state === "waiting", "state " + row.state);
    """)
  end

  test "sort: waiting, working, the latest activity, then the id" do
    run!("""
    const row = (id, needsYou, working, last) => ({id, needsYou, working, last});
    const rows = [
      row("b-idle", 0, 0, "2026-11-03T10:00:00Z"),
      row("a-idle", 0, 0, "2026-11-03T10:00:00Z"),
      row("never", 0, 0, ""),
      row("recent", 0, 0, "2026-11-03T12:00:00Z"),
      row("works", 0, 2, ""),
      row("works-more", 0, 3, ""),
      row("asks", 1, 0, ""),
      row("asks-more", 2, 0, "")
    ];
    const order = Projects.sort(rows).map(row => row.id).join();
    check(order === "asks-more,asks,works-more,works,recent,a-idle,b-idle,never", "order " + order);
    check(rows[0].id === "b-idle", "sort keeps its input");
    """)
  end

  test "filter by state chip and by the words of the id" do
    run!("""
    const rows = [
      {id: "agency", state: "waiting"}, {id: "Bakery-site", state: "working"}, {id: "dev", state: "idle"}
    ];
    const ids = (text, chip) => Projects.filter(rows, text, chip).map(row => row.id).join();
    check(ids("", "") === "agency,Bakery-site,dev", "all");
    check(ids("", "waiting") === "agency", "waiting");
    check(ids("", "working") === "Bakery-site", "working");
    check(ids("bakery SITE", "") === "Bakery-site", "words " + ids("bakery SITE", ""));
    check(ids("  ", "") === "agency,Bakery-site,dev", "blank");
    check(ids("dev", "waiting") === "", "both");
    """)
  end

  test "meta drops the working, the activity, then shortens, to fit its budget" do
    run!("""
    const row = {conversations: 15, needsYou: 12, working: 1};
    const meta = budget => Projects.meta(row, "Yesterday 22:43", budget, " · ");
    check(meta(200) === "15 conversations · 12 need you · 1 working · Yesterday 22:43", "200 " + meta(200));
    check(meta(50) === "15 conversations · 12 need you · Yesterday 22:43", "50 " + meta(50));
    check(meta(30) === "15 conversations · 12 need you", "30 " + meta(30));
    check(meta(22) === "15 conv. · 12 need you", "22 " + meta(22));
    check(meta(5) === "15 conv. · 12 need you", "the last candidate, to elide " + meta(5));
    for (const budget of [200, 50, 30, 22]) check(meta(budget).length <= budget, "fits " + budget);
    const one = {conversations: 1, needsYou: 1, working: 0};
    check(Projects.meta(one, "", 200, " · ") === "1 conversation · 1 needs you", "one " + Projects.meta(one, "", 200, " · "));
    const quiet = {conversations: 2, needsYou: 0, working: 0};
    check(Projects.meta(quiet, "Today 09:00", 200, " · ") === "2 conversations · Today 09:00", "nothing to count");
    """)
  end

  test "summary says whom a conversation is with and what waits on you, oldest first" do
    run!("""
    const human = {kind: "human", issuer: "local", subject: "me"};
    const agent = {kind: "agent", agent: "seller"};
    const request = (id, created_at, fields) => Object.assign({id, created_at, status: "pending", arbiter: human, options: {}, origins: {}}, fields);
    const summary = Projects.summary({
      prompts: [{kind: "message", body: "Hi!\\n  I want a website"}],
      runs: [
        {agent: "seller", depth: "1", status: "open", started_at: "2026-11-03T10:01:00Z"},
        {agent: "sales", depth: "0", status: "done", started_at: "2026-11-03T10:00:00Z"},
        {agent: "sales", depth: "0", status: "open", started_at: "2026-11-03T10:05:00Z"}
      ],
      works: [{state: "open"}],
      requests: [
        request("form", "2026-11-03T10:20:00Z", {reason: "Tell me:\\n1. pages?\\n2. colours?\\n3. deadline?"}),
        request("one", "2026-11-03T10:30:00Z", {reason: "Which domain?"}),
        request("pick", "2026-11-03T10:10:00Z", {reason: "Approve the preview?", options: {approve: [], adjust: []}}),
        request("grant", "2026-11-03T10:40:00Z", {reason: "May I publish?", options: {grant_once: [{name: "grant", args: {kind: "tool", name: "publish"}}], deny: []}}),
        request("theirs", "2026-11-03T09:00:00Z", {arbiter: agent, reason: "for an agent"}),
        request("closed", "2026-11-03T09:00:00Z", {status: "closed", reason: "done"})
      ]
    });
    check(summary.title === "Hi! I want a website" && summary.agent === "sales", "who " + JSON.stringify(summary));
    check(summary.started && !summary.finished && summary.running === 2, "runs " + JSON.stringify(summary));
    check(summary.waiting === 4 && summary.since === "2026-11-03T10:10:00Z", "waiting " + JSON.stringify(summary));
    check(JSON.stringify(summary.asks) === JSON.stringify({questions: 4, decisions: 1, permissions: 1}), "asks " + JSON.stringify(summary.asks));
    check(summary.question === "May I publish?", "newest " + summary.question);
    check(Projects.state(summary) === "needs-you", "state " + Projects.state(summary));
    check(Projects.waitsFor(summary.asks) === "A PERMISSION · A DECISION · 4 QUESTIONS", "waits " + Projects.waitsFor(summary.asks));
    check(Projects.waitsFor({questions: 1, decisions: 2, permissions: 0}) === "2 DECISIONS · A QUESTION", "plural");
    const empty = Projects.summary({prompts: [], runs: [], works: [], requests: []});
    check(empty.agent === "" && empty.since === "" && empty.question === "" && Projects.state(empty) === "not-started", "empty " + JSON.stringify(empty));
    """)
  end

  test "state: not started, needs you over working, done, idle, unread" do
    run!("""
    const s = fields => Object.assign({started: true, running: 0, waiting: 0, finished: false}, fields);
    check(Projects.state(null) === "", "unread");
    check(Projects.state(s({started: false, waiting: 1})) === "not-started", "not started");
    check(Projects.state(s({waiting: 1, running: 2})) === "needs-you", "needs you");
    check(Projects.state(s({running: 1, finished: true})) === "working", "working");
    check(Projects.state(s({finished: true})) === "done", "done");
    check(Projects.state(s({})) === "idle", "idle");
    """)
  end

  test "a project stays reading, counting none, until every summary is read" do
    run!("""
    const rows = Projects.rows(input({
      projects: [place("agency"), place("dev"), place("bare")],
      conversations: {agency: [conversation("a", ""), conversation("b", "")], dev: [conversation("d", "")]},
      summaries: {a: {started: true, waiting: 2}, d: {started: true, waiting: 1}},
      current: "bare"
    }));
    const by = byId(rows);
    check(by.agency.state === "reading" && by.agency.needsYou === 0, "partial " + JSON.stringify(by.agency));
    check(by.bare.state === "reading", "no list " + by.bare.state);
    check(by.dev.state === "waiting" && by.dev.needsYou === 1, "read " + JSON.stringify(by.dev));
    check(Projects.reading(rows) && Projects.elsewhere(rows) === 0, "no partial elsewhere");
    const done = Projects.rows(input({
      projects: [place("agency"), place("dev")],
      conversations: {agency: [conversation("a", "")], dev: [conversation("d", "")]},
      summaries: {a: {started: true, waiting: 2}, d: {started: true, waiting: 1}},
      current: "dev"
    }));
    check(!Projects.reading(done) && Projects.elsewhere(done) === 1, "complete " + Projects.elsewhere(done));
    """)
  end

  test "elsewhere sums the conversations needing you of every project but the open one" do
    run!("""
    const rows = Projects.rows(input({
      projects: [place("agency"), place("dev"), place("down")],
      conversations: {agency: [conversation("a", "")], dev: [conversation("d", ""), conversation("e", "")], down: [conversation("x", "")]},
      summaries: {a: {started: true, waiting: 2}, d: {started: true, waiting: 1}, e: {started: true, waiting: 4}, x: {started: true, waiting: 5}},
      unreachable: new Set(["down"]),
      current: "agency"
    }));
    check(Projects.elsewhere(rows) === 2, "elsewhere " + Projects.elsewhere(rows));
    """)
  end
end
