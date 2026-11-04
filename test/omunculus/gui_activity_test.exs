defmodule Omunculus.GuiActivityTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const human = {kind: "human", issuer: "local", subject: "1000"};
  const agent = name => ({kind: "agent", agent: name});
  const steps = ["brief", "design", "propose", "build", "review", "ship"].map(name => ({name, agent: name + "-agent"}));
  const lane = {name: "agency", steps, at: 1};
  const works = [
    {id: "w1", title: "Bakery site", state: "open", workflow: "agency", stage: "design"},
    {id: "w2", title: "Home page", state: "open", parent_id: "w1", assignee: "designer"}
  ];
  const run = (id, agentName, work, extra) => Object.assign({id, agent: agentName, depth: 1, work_id: work, status: "open"}, extra);
  const base = {runs: [], works, requests: [], lanes: {w1: lane}, calling: {}, runStarts: {}, now: 100};
  """

  defp run!(modules, assertions) do
    assert {"", 0} = GuiModules.run(modules, @fixtures <> assertions)
  end

  test "an open run under a waiting seller is working, with the stage" do
    run!(["Requests", "Phrases", "Activity"], """
    const seller = {id: "q1", status: "pending", arbiter: agent("design-lead"), requester: agent("seller"), work_id: "w1"};
    const out = Activity.status(Object.assign({}, base, {
      runs: [run("r1", "designer", "w2")], requests: [seller],
      calling: {w2: "write"}, runStarts: {r1: 40}
    }));
    if (out.state !== "working") throw Error("state " + out.state);
    if (out.since !== 40) throw Error("since");
    if (out.stage.name !== "design" || out.stage.index !== 2 || out.stage.count !== 6 || out.stage.next !== "propose")
      throw Error("stage " + JSON.stringify(out.stage));
    if (out.headline !== "DESIGN TEAM IS WORKING  -  DESIGNER: WRITING FILES  -  STEP 2 OF 6") throw Error(out.headline);
    const rows = Object.fromEntries(out.rows.map(r => [r.work, r]));
    if (rows.w1.state !== "waiting-team" || rows.w1.depth !== 0 || rows.w1.agent !== "design-agent") throw Error("w1 " + JSON.stringify(rows.w1));
    if (rows.w2.state !== "working" || rows.w2.phrase !== "Writing files" || rows.w2.since !== 40 || rows.w2.parent !== "w1" || rows.w2.depth !== 1)
      throw Error("w2 " + JSON.stringify(rows.w2));
    """)
  end

  test "a request for a person is waiting-you, none is idle" do
    run!(["Requests", "Phrases", "Activity"], """
    const ask = {id: "q1", status: "pending", arbiter: human, requester: agent("sales"), work_id: "w1"};
    const you = Activity.status(Object.assign({}, base, {runs: [run("r1", "designer", "w2")], requests: [ask]}));
    if (you.state !== "waiting-you" || you.headline !== "SALES IS WAITING FOR YOUR ANSWER") throw Error(JSON.stringify(you));
    const idle = Activity.status(base);
    if (idle.state !== "idle" || idle.headline !== "") throw Error("idle " + idle.state);
    const team = Activity.status(Object.assign({}, base, {requests: [
      {id: "q2", status: "pending", arbiter: agent("seller"), requester: agent("design-lead"), work_id: "w1"}]}));
    if (team.state !== "waiting-team" || team.headline !== "DESIGN-LEAD IS WAITING FOR SELLER") throw Error(team.headline);
    """)
  end

  test "failed, done and loops" do
    run!(["Requests", "Phrases", "Activity"], """
    const failed = Activity.status(Object.assign({}, base, {runs: [run("r1", "designer", "w2", {status: "done", error: "model refused\\nmore"})]}));
    if (failed.state !== "failed" || failed.headline !== "THE TEAM STOPPED: model refused  -  See the log") throw Error(failed.headline);
    const broken = Activity.status(Object.assign({}, base, {works: [{id: "w1", state: "waiting", title: "x"}]}));
    if (broken.state !== "failed" || broken.rows[0].state !== "failed") throw Error("broken");
    const done = Activity.status(Object.assign({}, base, {works: works.map(w => Object.assign({}, w, {state: "done"}))}));
    if (done.state !== "done" || done.headline !== "DELIVERED") throw Error("done");
    const loop = Activity.status(Object.assign({}, base, {runs: [
      run("r1", "designer", "w1", {status: "done"}), run("r2", "reviewer", "w1", {status: "done"}), run("r3", "designer", "w1")]}));
    if (loop.loop !== "REVIEWER SENT IT BACK TO DESIGNER, ROUND 2") throw Error("loop " + loop.loop);
    if (Activity.status(base).loop !== "") throw Error("no loop");
    """)
  end

  test "contained hides the lower requests of a climb; kind and chain" do
    run!(["Requests", "Phrases", "Activity"], """
    const low = {id: "a", status: "escalated", arbiter: agent("lead"), requester: agent("designer"), reason: "which font?", origins: {}};
    const mid = {id: "b", status: "escalated", arbiter: agent("seller"), requester: agent("lead"), reason: "font?", origins: {p: low}};
    const top = {id: "c", status: "pending", arbiter: human, requester: agent("seller"), reason: "Which font do you like?", origins: {q: mid}};
    const other = {id: "d", status: "pending", arbiter: human, requester: agent("sales"), reason: "Budget?"};
    const ids = Requests.contained([low, mid, top, other]);
    if (ids.size !== 2 || !ids.has("a") || !ids.has("b") || ids.has("c") || ids.has("d")) throw Error("contained");
    const names = Requests.chain(top).map(c => Requests.label(c.requester));
    if (names.join() !== "lead,designer") throw Error("chain " + names);
    if (Requests.chain(other).length !== 0) throw Error("empty chain");
    if (Requests.kind(top) !== "needs-you" || Requests.kind(other) !== "needs-you") throw Error("needs-you");
    if (Requests.kind(low) !== "team") throw Error("team");
    if (Requests.kind(Object.assign({}, other, {status: "closed"})) !== "team") throw Error("closed");
    const options = {approve: [{name: "reply"}]};
    if (Requests.kind(Object.assign({}, other, {options})) !== "decision") throw Error("decision");
    const grant = {approve: [{name: "grant", args: {kind: "tool", name: "write"}}]};
    if (Requests.kind(Object.assign({}, other, {options: grant})) !== "permission") throw Error("permission");
    """)
  end

  test "summarize speaks in phrases, counts failures and hides internal ones" do
    run!(["Phrases"], """
    const ok = name => ({name, ok: true});
    const bad = name => ({name, ok: false});
    const read6 = Array.from({length: 6}, () => ok("read"));
    let out = Phrases.summarize(read6.concat([ok("write")]));
    if (out.text !== "Read 6 files, wrote a file" || out.failed !== 0 || out.failedText !== "") throw Error(out.text);
    out = Phrases.summarize([ok("read"), bad("write"), bad("edit"), ok("read")]);
    if (out.text !== "Read 2 files") throw Error(out.text);
    if (out.failed !== 2 || out.failedText !== "2 attempts did not work") throw Error(JSON.stringify(out));
    out = Phrases.summarize([bad("next_stage"), bad("next_stage"), bad("next_stage"), ok("ls")]);
    if (out.hidden !== 3 || out.failed !== 0 || out.failedText !== "" || out.text !== "Looked at the project") throw Error(JSON.stringify(out));
    out = Phrases.summarize(Array.from({length: 4}, () => bad("next_stage")));
    if (out.hidden !== 0 || out.failed !== 4 || out.failedText !== "The team is having trouble moving on") throw Error(JSON.stringify(out));
    if (Phrases.summarize([ok("mystery")]).text !== "Worked") throw Error("unknown");
    if (Phrases.phrase("read") !== "Reading files" || Phrases.phrase("mystery") !== "Working") throw Error("phrase");
    """)
  end
end
