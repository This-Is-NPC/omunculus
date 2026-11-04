defmodule Omunculus.GuiProgressTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @modules ["Requests", "Questions", "Phrases", "Usage", "Time", "Progress"]

  # A sale at its design stage (w1), a design-lead work handed down in it
  # waiting on its child (w2), and a design work sent back once from review
  # (w3), its designer running; times in seconds, stamps as the server's.
  @fixtures """
  const iso = t => new Date(t * 1000).toISOString();
  const human = {kind: "human", issuer: "local", subject: "1000"};
  const agent = name => ({kind: "agent", agent: name});
  const by = name => ({kind: "agent", id: name});
  const check = (ok, what, value) => { if (!ok) throw Error(what + " " + JSON.stringify(value)); };
  const sale = {name: "sale", steps: ["qualify", "design", "assess", "propose", "owner", "build"].map(name => ({name, agent: "seller"}))};
  const design = {name: "design", steps: [{name: "design", agent: "designer"}, {name: "review", agent: "design-reviewer"}, {name: "publish", agent: "publisher"}]};
  const works = [
    {id: "w1", title: "Bakery website", state: "waiting", waiting: "child", workflow: "sale", stage: "design", assignee: "seller", created_at: iso(1000), updated_at: iso(1200)},
    {id: "w2", title: "Design preview", state: "waiting", waiting: "child", parent_id: "w1", assignee: "design-lead", created_at: iso(1300), updated_at: iso(1400)},
    {id: "w3", title: "Home page", state: "open", workflow: "design", stage: "design", parent_id: "w2", assignee: "designer", created_at: iso(1400), updated_at: iso(1700)}
  ];
  const lanes = {w1: Object.assign({at: 1}, sale), w2: null, w3: Object.assign({at: 0}, design)};
  const events = [
    {type: "continue", work_id: "w1", at: iso(1200), actor: by("seller"), body: {from: "qualify", to: "design"}},
    {type: "delegate", work_id: "w2", at: iso(1300), actor: by("seller"), body: {title: "Design preview", goal: "g", parent_id: "w1"}},
    {type: "delegate", work_id: "w3", at: iso(1400), actor: by("design-lead"), body: {title: "Home page", goal: "g", parent_id: "w2"}},
    {type: "continue", work_id: "w3", at: iso(1500), actor: by("designer"), body: {from: "design", to: "review"}},
    {type: "break", work_id: "w3", at: iso(1600), actor: by("design-reviewer"), body: {body: "the menu overlaps the logo\\nat 375 px", parent_id: "w2"}},
    {type: "reopen", work_id: "w3", at: iso(1700), actor: by("design-lead"), body: {parent_id: "w2", stage: "design"}}
  ];
  const journeys = events.reduce((all, event) => Progress.journal(all, event), {});
  const run = (id, name, work, extra) => Object.assign({id, agent: name, depth: 1, work_id: work, status: "open"}, extra);
  const base = {works, lanes, journeys, runs: [run("r3", "designer", "w3")], runStarts: {r3: 1900},
    requests: [], calling: {w3: "write"}, callArgs: {w3: {path: "site/index.html", content: "x"}}, rootAgent: "sales", now: 2000};
  const nodes = out => Object.fromEntries(out.flat.map(node => [node.work, node]));
  """

  defp run!(assertions) do
    assert {"", 0} = GuiModules.run(@modules, @fixtures <> assertions)
  end

  test "journal keeps the stages entered, the rounds and who sent a work back" do
    run!("""
    const w3 = journeys.w3;
    check(JSON.stringify(w3.entered) === JSON.stringify([
      {stage: "review", at: 1500, round: 0, from: "design"}, {stage: "design", at: 1700, round: 2}]), "entered", w3.entered);
    check(w3.rounds === 1 && w3.stopped === null && w3.finishedAt === null, "rounds", w3);
    check(JSON.stringify(w3.sentBack) === JSON.stringify({by: "design-reviewer", why: "the menu overlaps the logo", at: 1600}), "sentBack", w3.sentBack);
    check(journeys.w2 === undefined, "a delegate enters nothing", journeys.w2);
    const moved = Progress.journal(journeys, {type: "continue", work_id: "w3", at: iso(1800), body: {from: "design", to: "review"}});
    check(moved.w3.entered.length === 3 && moved.w3.entered[2].round === 2 && moved.w3.rounds === 1, "continue after reopen", moved.w3);
    check(journeys.w3.entered.length === 2, "journal copies", journeys.w3);
    const finished = Progress.journal(moved, {type: "continue", work_id: "w3", at: iso(1900), body: {from: "publish", to: null}});
    check(finished.w3.finishedAt === 1900 && finished.w3.entered.length === 3, "finished", finished.w3);
    const stopped = Progress.journal(journeys, {type: "break", work_id: "w1", at: iso(1250), actor: by("seller"), body: {body: "no budget"}});
    check(JSON.stringify(stopped.w1.stopped) === JSON.stringify({by: "seller", why: "no budget", at: 1250}), "stopped", stopped.w1);
    """)
  end

  test "journal returns the same object for any other event" do
    run!("""
    for (const type of ["tool", "model", "prompt", "delegate", "work", "start-run", "end-run"])
      check(Progress.journal(journeys, {type, work_id: "w3", at: iso(1), body: {}}) === journeys, "same for", type);
    check(Progress.journal(journeys, {type: "continue", at: iso(1), body: {to: "x"}}) === journeys, "no work", "");
    """)
  end

  test "build nests three levels under the stage that handed them down" do
    run!("""
    const out = Progress.build(base);
    const n = nodes(out);
    check(out.state === "working", "state", out.state);
    check(out.roots.length === 1 && out.focus === out.roots[0] && out.focus.work === "w1", "focus", out.focus && out.focus.work);
    check(out.flat.map(node => node.work).join() === "w1,w2,w3", "flat", out.flat.map(node => node.work));
    check(out.roots[0].steps[1].children.length === 1 && out.roots[0].steps[1].children[0].work === "w2", "w2 under design", out.roots[0].steps[1]);
    check(out.roots[0].steps[0].children.length === 0 && out.roots[0].children.length === 0, "only there", out.roots[0].steps[0]);
    check(n.w2.children.length === 1 && n.w2.children[0].work === "w3" && n.w2.steps.length === 0, "w2 has w3", n.w2.children);
    check(n.w1.level === 0 && n.w2.level === 1 && n.w3.level === 2 && n.w3.parent === "w2", "levels", [n.w1.level, n.w2.level, n.w3.level]);
    check(n.w1.state === "waiting" && n.w1.waitingOn === "design-lead" && n.w1.agent === "seller" && n.w1.at === 1 && n.w1.count === 6, "w1", n.w1);
    check(n.w2.state === "waiting" && n.w2.waitingOn === "designer" && n.w2.doing === "Waiting for designer", "w2", n.w2);
    check(n.w3.state === "working" && n.w3.word === "Working" && n.w3.since === 1900 && n.w3.doing === "Writing files", "w3", n.w3);
    check(JSON.stringify(n.w3.lastCall) === JSON.stringify({name: "write", brief: "site/index.html"}), "lastCall", n.w3.lastCall);
    check(n.w3.round === 2 && n.w3.sentBack.by === "design-reviewer" && n.w3.stopped === null, "round", n.w3);
    check(JSON.stringify(n.w3.team) === JSON.stringify([{agent: "designer", current: true}, {agent: "design-reviewer", current: false}, {agent: "publisher", current: false}]), "team", n.w3.team);
    check(JSON.stringify(n.w2.team) === JSON.stringify([{agent: "design-lead", current: true}]), "team of one", n.w2.team);
    check(n.w3.steps.map(step => step.status).join() === "current,next,next", "w3 statuses", n.w3.steps);
    check(out.path.map(each => each.agent).join(" › ") === "seller › design-lead › designer", "path", out.path);
    check(out.path[2].title === "Home page" && out.path[2].work === "w3", "path leaf", out.path[2]);
    check(JSON.stringify(out.now) === JSON.stringify({agent: "designer", doing: "Writing files", since: 1900}), "now", out.now);
    check(out.counts.working === 1 && out.counts.waiting === 2 && out.counts.total === 3 && out.counts.agents === 1, "counts", out.counts);
    check(out.spoken === "Working. seller, design-lead, designer: Writing files", "spoken", out.spoken);
    """)
  end

  test "needs you wins over working; stopped and failed by the run's error" do
    run!("""
    const ask = {id: "q1", status: "pending", arbiter: human, requester: agent("seller"), work_id: "w1", reason: "What is the bakery called?\\nAnd where?"};
    const out = Progress.build(Object.assign({}, base, {requests: [ask]}));
    check(out.state === "needs-you" && nodes(out).w1.state === "needs-you" && nodes(out).w1.doing === "Waiting for your answer", "needs-you", out.state);
    check(JSON.stringify(out.forYou) === JSON.stringify([{id: "q1", asker: "seller", work: "w1", title: "Bakery website", question: ask.reason, kind: "needs-you", asks: 1}]), "forYou", out.forYou);
    check(out.spoken === "seller asks you: What is the bakery called?", "spoken", out.spoken);
    check(out.path.map(each => each.agent).join() === "seller,design-lead,designer", "path keeps going down", out.path);
    const broken = [{id: "w9", title: "Menu", state: "waiting", assignee: "designer", created_at: iso(1000), updated_at: iso(1100)}];
    const stopJournal = Progress.journal({}, {type: "break", work_id: "w9", at: iso(1100), actor: by("designer"), body: {body: "no menu given"}});
    const stopped = Progress.build({works: broken, lanes: {}, journeys: stopJournal, runs: [run("r9", "designer", "w9", {status: "done"})], now: 2000});
    const s = stopped.flat[0];
    check(stopped.state === "stopped" && s.state === "stopped" && s.doing === "Stopped by designer: no menu given", "stopped", s);
    check(s.stopped.by === "designer" && s.since === 1100, "stopped by", s.stopped);
    const failed = Progress.build({works: broken, lanes: {}, runs: [run("r9", "designer", "w9", {status: "done", error: "model refused\\nmore"})], now: 2000});
    check(failed.state === "failed" && failed.flat[0].doing === "Failed: model refused" && failed.flat[0].stopped === null, "failed", failed.flat[0]);
    const done = Progress.build({works: [{id: "w9", title: "Menu", state: "done", created_at: iso(1000), updated_at: iso(1720)}], now: 2000});
    check(done.state === "done" && done.flat[0].doing === "Done in 12 min" && done.flat[0].finishedIn === 720 && done.flat[0].since === null, "done", done.flat[0]);
    const waiting = Progress.build(Object.assign({}, base, {runs: []}));
    check(waiting.state === "waiting" && nodes(waiting).w3.state === "up-next" && nodes(waiting).w3.doing === "Up next", "no run", waiting.state);
    check(waiting.now.agent === "designer" && waiting.now.doing === "Up next" && waiting.now.since === 1700, "now at the leaf", waiting.now);
    check(Progress.build({works: [], now: 1}).state === "idle", "idle", "");
    """)
  end

  # c1-05: the sale at its design stage waits on a request; the seller's
  # request was escalated by sales, whose run has no work, to you.
  test "a work's state follows its question up the escalation climb" do
    run!("""
    const doneWorks = works.map(work => work.id === "w1"
      ? Object.assign({}, work, {waiting: "request"}) : Object.assign({}, work, {state: "done"}));
    const seller = {id: "s1", status: "escalated", arbiter: agent("sales"), requester: agent("seller"), work_id: "w1", reason: "Approve the design preview?", origins: {}};
    const sales = {id: "p1", status: "pending", arbiter: human, requester: agent("sales"), work_id: null, reason: "Do you approve the preview?", origins: {seller: seller}};
    const at = requests => Progress.build(Object.assign({}, base, {works: doneWorks, runs: [], requests}));
    const asked = at([seller, sales]);
    const n = nodes(asked);
    check(asked.state === "needs-you" && n.w1.state === "needs-you" && n.w1.doing === "Waiting for your answer", "needs you", n.w1);
    check(asked.forYou.length === 1 && asked.forYou[0].work === "w1" && asked.forYou[0].title === "Bakery website" && asked.forYou[0].asker === "seller", "forYou", asked.forYou);
    check(n.w1.asks.length === 1 && n.w1.asks[0].id === "p1" && n.w1.asks[0].human, "asks", n.w1.asks);
    check(n.w2.state === "done" && n.w3.state === "done", "done below", [n.w2.state, n.w3.state]);
    const toSales = nodes(at([seller, Object.assign({}, sales, {arbiter: agent("sales")})]));
    check(toSales.w1.state === "waiting" && toSales.w1.waitingOn === "sales", "waiting on the holder", toSales.w1);
    const unheld = nodes(at([seller]));
    check(unheld.w1.state === "waiting" && unheld.w1.doing === "Waiting for an answer", "a question not found yet", unheld.w1);
    """)
  end

  test "the deepest work of a climb asks; the works above say it needs you below" do
    run!("""
    const low = {id: "a", status: "escalated", arbiter: agent("design-lead"), requester: agent("designer"), work_id: "w3", reason: "Which logo?", origins: {}};
    const top = {id: "c", status: "pending", arbiter: human, requester: agent("sales"), work_id: null, reason: "Which logo?", origins: {p: low}};
    const out = Progress.build(Object.assign({}, base, {runs: [], requests: [low, top]}));
    const n = nodes(out);
    check(n.w3.state === "needs-you" && out.forYou[0].work === "w3" && out.forYou[0].title === "Home page", "deepest", out.forYou);
    check(n.w2.state === "waiting" && n.w2.waitingOn === "designer" && n.w2.below === "c", "child keeps waiting", n.w2);
    check(n.w1.state === "waiting" && n.w1.below === "c" && n.w3.below === "", "below", [n.w1.below, n.w3.below]);
    const plain = nodes(Progress.build(base));
    check(plain.w1.below === "" && plain.w2.below === "", "nothing below", plain.w1.below);
    """)
  end

  test "a question counts once: the works it climbed through wait for your answer" do
    run!("""
    const low = {id: "a", status: "escalated", arbiter: agent("seller"), requester: agent("designer"), work_id: "w3", reason: "Which logo?", origins: {}};
    const mid = {id: "b", status: "escalated", arbiter: agent("sales"), requester: agent("seller"), work_id: "w2", reason: "passed", origins: {p: low}};
    const top = {id: "c", status: "pending", arbiter: human, requester: agent("sales"), work_id: null, reason: "Which logo?", origins: {p: mid}};
    const out = Progress.build(Object.assign({}, base, {runs: [], requests: [low, mid, top]}));
    const n = nodes(out);
    check(n.w3.state === "needs-you" && n.w3.asks.length === 1 && n.w3.asks[0].id === "c", "asker", n.w3);
    check(n.w2.state === "waiting" && n.w2.word === "Waiting" && n.w2.doing === "Waiting for your answer to designer" && n.w2.asks.length === 0 && n.w2.below === "", "passer", n.w2);
    check(n.w1.below === "c" && out.flat.filter(each => each.state === "needs-you").length === 1 && out.forYou.length === 1 && out.forYou[0].asker === "designer", "once", out.forYou);
    """)
  end

  test "underway lists who works below a work, and opened what an outline shows under it" do
    run!("""
    const out = Progress.build(base);
    const n = nodes(out);
    check(Progress.underway(n.w1).map(node => node.work).join() === "w3", "w3 works below w1", Progress.underway(n.w1));
    check(Progress.underway(n.w3).length === 0, "nothing below w3", "");
    check(Progress.opened(n.w1, []).map(node => node.work).join() === "w2", "running below", "");
    check(Progress.opened(n.w2, []).map(node => node.work).join() === "w3", "running below, one deeper", "");
    const idle = Progress.build(Object.assign({}, base, {runs: [], runStarts: {}}));
    const still = nodes(idle);
    check(Progress.opened(still.w2, []).length === 0, "idle, off the path", "");
    check(Progress.opened(still.w2, [{work: "w2"}]).map(node => node.work).join() === "w3", "on the path", "");
    """)
  end

  test "finished folds done and cancelled sub-works into one line" do
    run!("""
    const node = (state, created, seconds) => ({state, created, branch: {seconds}});
    check(Progress.finished([node("done", 100, 300), node("done", 200, 980)]) === "2 sub-works done · 18 min", "two", "");
    check(Progress.finished([node("done", 100, 42), node("cancelled", 110, 10)]) === "1 sub-work done · 42 s · 1 cancelled", "cancelled", "");
    check(Progress.finished([node("cancelled", 100, 5)]) === "1 sub-work cancelled · 5 s", "only cancelled", "");
    """)
  end

  test "below says in plain words what a work handed down" do
    run!("""
    const kids = states => states.map(state => ({state}));
    check(Progress.below([]) === "", "none", "");
    check(Progress.below(kids(["done"])) === "1 sub-work done", "one done", "");
    check(Progress.below(kids(["done", "cancelled"])) === "2 sub-works done", "all finished", "");
    check(Progress.below(kids(["working", "done"])) === "2 sub-works, 1 working, 1 done", "working", "");
    check(Progress.below(kids(["working", "waiting"])) === "2 sub-works, 1 working", "working only", "");
    check(Progress.below(kids(["waiting", "done", "up-next"])) === "3 sub-works, 1 done", "some done", "");
    check(Progress.below(kids(["waiting"])) === "1 sub-work", "open", "");
    """)
  end

  test "step seconds count a stage visited twice, and again marks a stage due again" do
    run!("""
    const n = nodes(Progress.build(base));
    check(n.w3.steps.map(step => step.seconds).join() === "400,200,0", "w3 seconds", n.w3.steps.map(step => step.seconds));
    check(n.w3.steps.map(step => step.again).join() === "false,true,false", "again", n.w3.steps.map(step => step.again));
    check(n.w1.steps.map(step => step.seconds).join() === "200,800,0,0,0,0", "w1 seconds", n.w1.steps.map(step => step.seconds));
    check(n.w1.steps.map(step => step.status).join() === "done,current,next,next,next,next", "w1 statuses", n.w1.steps);
    const finished = Progress.journal(journeys, {type: "continue", work_id: "w3", at: iso(1800), body: {from: "design", to: "review"}});
    const closed = Progress.journal(finished, {type: "continue", work_id: "w3", at: iso(1850), body: {from: "review", to: null}});
    const doneWorks = works.map(work => work.id === "w3" ? Object.assign({}, work, {state: "done", stage: "review"}) : work);
    const d = nodes(Progress.build(Object.assign({}, base, {works: doneWorks, journeys: closed, lanes: Object.assign({}, lanes, {w3: Object.assign({at: 1}, design)}), runs: []}))).w3;
    check(d.steps.map(step => step.seconds).join() === "200,250,0", "ends when finished", d.steps.map(step => step.seconds));
    check(d.steps.every(step => step.status === "done") && d.finishedIn === 450 && d.doing === "Done in 7 min", "done stages", d);
    """)
  end

  test "the front agent heads a team of other agents' works" do
    run!("""
    const out = Progress.build(base);
    check(out.front && out.front.agent === "sales" && out.front.agents === 1 && out.front.asking === "" && out.front.ask === "", "front", out.front);
    const same = Progress.build(Object.assign({}, base, {rootAgent: "seller"}));
    check(out.front.state === "waiting" && out.front.doing === "Waiting for seller" && out.front.since === null, "front waits for its team", out.front);
    const finished = Progress.build(Object.assign({}, base, {runs: [], works: works.map(work => Object.assign({}, work, {state: "done"}))}));
    check(finished.front.state === "idle" && finished.front.doing === "", "front idle once nothing is open", finished.front);
    const talking = Progress.build(Object.assign({}, base, {runs: base.runs.concat([run("rf", "sales", "")])}));
    check(talking.front.state === "working" && talking.front.doing === "Getting started" && talking.front.since === null, "front working", talking.front);
    check(same.front === null, "root work is the front agent's own", same.front);
    check(Progress.build({works: [], rootAgent: "sales", now: 60}).front === null, "no works", "");
    """)
  end

  test "a depth-0 run without any work is working, with no focus" do
    run!("""
    const out = Progress.build({works: [], runs: [run("r0", "sales", "", {depth: 0})], runStarts: {r0: 50}, rootAgent: "sales", now: 60});
    check(out.state === "working" && out.focus === null && out.roots.length === 0 && out.path.length === 0, "working", out);
    check(JSON.stringify(out.now) === JSON.stringify({agent: "sales", doing: "Getting started", since: 50, loose: true}), "now", out.now);
    const asking = Progress.build({works: [], runs: [run("r0", "sales", "", {depth: 0})], calling: {"": "ask"}, rootAgent: "sales", now: 60});
    check(asking.now.doing === "Asking a teammate", "calling", asking.now);
    const answer = {id: "q9", status: "answered", arbiter: human, requester: agent("seller"), work_id: null, reason: "x", origins: {}};
    const replying = Progress.build({works: [], runs: [run("r0", "sales", "", {depth: 0})], calling: {"": "reply"}, callArgs: {"": {request_id: "q9"}}, requests: [answer], rootAgent: "sales", now: 60});
    check(replying.now.doing === "Passed your answers to seller", "live reply says what the finished one will", replying.now);
    const idle = Progress.build({works: [], rootAgent: "sales", now: 60});
    check(idle.state === "idle" && idle.now.agent === "sales" && idle.now.doing === "" && idle.spoken === "", "idle", idle);
    """)
  end

  test "stepper picks the longest form that fits" do
    run!("""
    const steps = sale.steps.map((step, i) => ({name: step.name, status: i < 1 ? "done" : i === 1 ? "current" : "next"}));
    const text = budget => { const out = Progress.stepper(steps, 2, budget); return out.form + " " + out.tokens.map(t => t.text).join(""); };
    const expected = {
      80: "F1 ✓ qualify › ● design · round 2 › ○ assess › ○ propose › ○ owner › ○ build",
      46: "F3 ✓ qualify › ● design · round 2 › ○ assess › +3",
      30: "F4 ✓1 › ● design r2 › ○ assess +3",
      22: "F5 ✓ ● ○ ○ ○ ○  design r2",
      13: "F6 2/6 design r2",
      8: "F6 2/6 des…"
    };
    for (const budget of Object.keys(expected)) check(text(Number(budget)) === expected[budget], "budget " + budget, text(Number(budget)));
    for (let budget = 0; budget <= 90; budget++) {
      const out = Progress.stepper(steps, 2, budget);
      check(out.tokens.map(t => t.text).join("").length <= budget, "fits", budget);
    }
    const tokens = Progress.stepper(steps, 2, 80).tokens;
    check(tokens[0].status === "done" && tokens[1].status === "separator" && tokens[2].status === "current" && tokens[4].status === "next", "statuses", tokens);
    const later = sale.steps.map((step, i) => ({name: step.name, status: i < 3 ? "done" : i === 3 ? "current" : "next"}));
    const f2 = Progress.stepper(later, 0, 40);
    check(f2.form === "F2" && f2.tokens.map(t => t.text).join("") === "✓ 3 › ● propose › ○ owner › ○ build", "F2", f2);
    check(Progress.stepper(later, 0, 74).form === "F1", "F1 when it fits", "");
    const all = sale.steps.map(step => ({name: step.name, status: "done"}));
    check(Progress.stepper(all, 0, 11).tokens.map(t => t.text).join("") === "✓ 6", "all done counted", "");
    check(Progress.stepper(all, 0, 2).tokens.map(t => t.text).join("") === "✓6", "all done short", "");
    check(Progress.stepper(all, 0, 1).tokens.map(t => t.text).join("") === "…", "all done elided", "");
    check(Progress.stepper([], 0, 10).tokens.length === 0, "no steps", "");
    """)
  end

  test "fit shortens, elides, drops and never exceeds the budget" do
    run!("""
    const parts = [
      {text: "seller › design-lead › designer", short: "…› designer", keep: true},
      {text: ": "},
      {text: "Writing files for the home page", elide: true, keep: true},
      {text: " · 4:12", keep: true}
    ];
    const total = texts => texts.join("").length;
    check(Progress.fit(parts, 80).join("") === "seller › design-lead › designer: Writing files for the home page · 4:12", "whole", "");
    check(Progress.fit(parts, 52).join("") === "…› designer: Writing files for the home page · 4:12", "short first", Progress.fit(parts, 52));
    check(Progress.fit(parts, 30).join("") === "…› designer: Writing f… · 4:12", "elide", Progress.fit(parts, 30));
    check(Progress.fit(parts, 25).join("") === "…› designer: Writ… · 4:12", "elide to 4", Progress.fit(parts, 25));
    const dropped = Progress.fit(parts, 23);
    check(dropped.length === 4 && dropped[1] === "" && dropped.join("") === "…› designerWrit… · 4:12", "drop before cut", dropped);
    check(Progress.fit(parts, 22).join("") === "…› designerWri… · 4:12", "then the elided part again", Progress.fit(parts, 22));
    for (let budget = 0; budget <= 80; budget++) check(total(Progress.fit(parts, budget)) <= budget, "fits", budget);
    """)
  end

  test "what you are asked is counted as its card counts it" do
    run!("""
    const form = {id: "q1", status: "pending", arbiter: human, requester: agent("seller"), work_id: "w1", reason: "Tell us:\\n1. The name?\\n2. The city?\\n3. The budget?"};
    const out = Progress.build(Object.assign({}, base, {requests: [form]}));
    check(out.forYou[0].kind === "needs-you" && out.forYou[0].asks === 3, "form items", out.forYou);
    check(Progress.asking(out.forYou) === "3 questions", "asking form", Progress.asking(out.forYou));
    const passed = {id: "q2", status: "pending", arbiter: human, requester: {kind: "harness"}, work_id: "w1", reason: "passed on",
      origins: {a: {requester: agent("designer"), reason: "1. Colours?\\n2. Fonts?"}}};
    const relayed = Progress.build(Object.assign({}, base, {requests: [passed], noted: {q2: true}}));
    check(relayed.forYou[0].asker === "designer" && relayed.forYou[0].asks === 2, "passed on", relayed.forYou);
    const one = kind => [{kind: kind, asks: 1}];
    check(Progress.asking(one("needs-you")) === "1 question", "one question", Progress.asking(one("needs-you")));
    check(Progress.asking(one("decision")) === "to decide", "decision", Progress.asking(one("decision")));
    check(Progress.asking(one("permission")) === "for a permission", "permission", Progress.asking(one("permission")));
    const mixed = [{kind: "needs-you", asks: 7}, {kind: "decision", asks: 1}, {kind: "decision", asks: 1}];
    check(Progress.asking(mixed) === "7 questions, 2 decisions", "mixed", Progress.asking(mixed));
    """)
  end

  test "agents are named in the order they first ran" do
    run!("""
    const runs = [run("r1", "sales", ""), run("r2", "designer", "w3", {status: "done"}), run("r3", "sales", "")];
    const out = Progress.build(Object.assign({}, base, {runs: runs}));
    check(out.agents.join() === "sales,designer" && out.counts.agents === 2, "agents", out.agents);
    """)
  end

  test "span, duration and clock" do
    run!("""
    const durations = [[0, "0 seconds"], [1, "1 second"], [8, "8 seconds"], [60, "1 minute"], [180, "3 minutes"], [3600, "1 hour"], [3900, "1 hour 5 minutes"], [7260, "2 hours 1 minute"], [-5, "0 seconds"]];
    for (const [s, text] of durations) check(Progress.duration(s) === text, "duration " + s, Progress.duration(s));
    const spans = [[0, "0 s"], [42, "42 s"], [59.9, "59 s"], [180, "3 min"], [3599, "59 min"], [3900, "1 h 05 min"], [-5, "0 s"]];
    for (const [s, text] of spans) check(Progress.span(s) === text, "span " + s, Progress.span(s));
    const clocks = [[42, "0:42"], [725, "12:05"], [3723, "1:02:03"], [0, "0:00"]];
    for (const [s, text] of clocks) check(Progress.clock(s) === text, "clock " + s, Progress.clock(s));
    """)
  end

  test "siblings handed down in one stage form a parallel group" do
    run!("""
    const twins = works.concat([{id: "w5", title: "Menu page", state: "done", parent_id: "w1", assignee: "designer", created_at: iso(1350), updated_at: iso(1900)}]);
    const n = nodes(Progress.build(Object.assign({}, base, {works: twins})));
    check(n.w1.groups.length === 1, "one group", n.w1.groups);
    const group = n.w1.groups[0];
    check(group.step === "design" && group.parallel === true && group.nodes.map(node => node.work).join() === "w2,w5", "group", group);
    check(JSON.stringify(group.counts) === JSON.stringify({working: 0, waiting: 1, done: 1, total: 2}), "counts", group.counts);
    check(n.w2.groups.length === 1 && n.w2.groups[0].step === "" && n.w2.groups[0].parallel === false, "alone", n.w2.groups);
    """)
  end

  test "a request shows on the work that asks and on the work that decides" do
    run!("""
    const ask = {id: "q2", status: "pending", arbiter: agent("design-lead"), requester: agent("designer"), work_id: "w3", reason: "Which logo file?"};
    const you = {id: "q3", status: "pending", arbiter: human, requester: agent("seller"), work_id: "w1", reason: "Budget?",
      origins: {p: {id: "q0", status: "escalated", requester: agent("design-lead"), reason: "Budget?"}}};
    const n = nodes(Progress.build(Object.assign({}, base, {requests: [ask, you]})));
    check(JSON.stringify(n.w3.asks) === JSON.stringify([{id: "q2", to: "design-lead", human: false, question: "Which logo file?", toWork: "w2", chain: ["designer", "design-lead"]}]), "asks", n.w3.asks);
    check(JSON.stringify(n.w2.asked) === JSON.stringify([{id: "q2", from: "designer", fromWork: "w3", question: "Which logo file?", asks: 1}]), "asked", n.w2.asked);
    check(n.w1.asks.length === 1 && n.w1.asks[0].to === "you" && n.w1.asks[0].human && n.w1.asks[0].toWork === null, "you", n.w1.asks);
    check(n.w1.asks[0].chain.join(" › ") === "design-lead › seller › you", "chain", n.w1.asks[0].chain);
    check(n.w1.asked.length === 0 && n.w3.asked.length === 0, "none asked", "");
    const many = Object.assign({}, ask, {reason: "1. Which logo?\\n2. Which colour?\\n3. Which font?"});
    const m = nodes(Progress.build(Object.assign({}, base, {requests: [many]})));
    check(m.w2.asked.length === 1 && m.w2.asked[0].asks === 3, "numbered asks", m.w2.asked);
    """)
  end

  test "branch totals sum usage, agent time and steps bottom-up" do
    run!("""
    const runs = [
      run("r1", "seller", "w1", {status: "done", started_at: iso(1000), finished_at: iso(1100)}),
      run("r2", "design-lead", "w2", {status: "done", started_at: iso(1300), finished_at: iso(1360)}),
      run("r4", "designer", "w3", {status: "done", started_at: iso(1400), finished_at: iso(1500)}),
      run("r3", "designer", "w3", {started_at: iso(1900)})
    ];
    const tally = (calls, cost) => Object.assign(Usage.tally(), {calls, input: calls * 10, cost, priced: calls});
    const usage = {w1: tally(2, 0.5), w2: tally(1, 0.25), w3: tally(3, 0.125)};
    const calls = {w1: {count: 5, failed: 1, last: {text: "moved on to design", at: 1200}}, w2: {count: 2, failed: 0, last: null}, w3: {count: 7, failed: 2, last: null}};
    const n = nodes(Progress.build(Object.assign({}, base, {runs, runStarts: {r3: 1900}, usage, calls})));
    check(JSON.stringify(n.w3.own) === JSON.stringify({seconds: 600, agentSeconds: 200, calls: 7, failed: 2, usage: usage.w3}), "w3 own", n.w3.own);
    check(n.w3.calls === 7 && n.w3.failed === 2 && n.w1.last.text === "moved on to design", "calls", n.w1.last);
    const b = n.w1.branch;
    check(b.agentSeconds === 360 && b.works === 3 && b.calls === 14 && b.running === 1 && b.agents === 3 && b.seconds === 1000, "w1 branch", b);
    check(b.usage.calls === 6 && b.usage.input === 60 && b.usage.cost === 0.875 && b.usage.priced === 6, "usage", b.usage);
    check(n.w2.branch.agents === 2 && n.w2.branch.agentSeconds === 260 && n.w2.calls === 2 && n.w2.branch.calls === 9, "w2 branch", n.w2.branch);
    check(n.w1.own.usage.calls === 2 && n.w1.own.agentSeconds === 100, "w1 own", n.w1.own);
    """)
  end
end
