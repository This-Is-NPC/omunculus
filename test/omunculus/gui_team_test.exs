defmodule Omunculus.GuiTeamTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @modules ["Requests", "Questions", "Phrases", "Usage", "Time", "Progress", "Team"]

  # An agency run four levels deep, as the TEAM page's tree shows it: sales
  # talks with you; seller's sale (w1) handed down a design preview to
  # design-lead (w2, done, its design work w3 under it) and a question to
  # language_lawyer (w4, done) and the build to administrator (w5), who handed
  # down the toolsmith's set-up (w6, done) and six pages, surgeon then copilot:
  # two done, one working, one asking you through administrator › seller ›
  # sales, two up next. `done` is the same run delivered, with the release.
  @fixtures """
  const check = (ok, what, value) => { if (!ok) throw Error(what + " " + JSON.stringify(value)); };
  const iso = t => new Date(t * 1000).toISOString();
  const human = {kind: "human", issuer: "local", subject: "1000"};
  const agent = name => ({kind: "agent", agent: name});
  const flow = (name, steps) => ({name, steps: steps.map(([step, who]) => ({name: step, agent: who}))});
  const sale = flow("sale", ["qualify", "design", "assess", "propose", "owner", "build"].map(step => [step, "seller"]));
  const design = flow("design", [["design", "designer"], ["review", "design-reviewer"], ["publish", "publisher"]]);
  const page = flow("page", [["build", "surgeon"], ["review", "copilot"]]);
  const agency = done => {
    const works = [], lanes = {};
    const work = (id, parent, assignee, created, state, lane, extra) => {
      works.push(Object.assign({id, title: id, parent_id: parent, assignee, state, created_at: iso(created), updated_at: iso(created + 100)}, extra || {}));
      lanes[id] = lane;
    };
    work("w1", null, "seller", 0, done ? "done" : "waiting", Object.assign({at: 5}, sale), {waiting: "child"});
    work("w2", "w1", "design-lead", 100, "done", null);
    work("w3", "w2", "designer", 200, "done", Object.assign({at: 2}, design));
    work("w4", "w1", "language_lawyer", 300, "done", null);
    work("w5", "w1", "administrator", 400, done ? "done" : "waiting", null, {waiting: "child"});
    work("w6", "w5", "toolsmith", 500, "done", null);
    ["home", "menu", "about", "order", "contact", "gallery"].forEach((name, i) => {
      const state = done || i < 2 ? "done" : i === 3 ? "waiting" : "open";
      work(name, "w5", "surgeon", 600 + i, state, Object.assign({at: state === "done" ? 1 : 0}, page), i === 3 ? {waiting: "request"} : {});
    });
    if (done) work("w7", "w5", "clerk", 900, "done", null);
    const low = {id: "q1", status: "escalated", arbiter: agent("administrator"), requester: agent("surgeon"), work_id: "order", reason: "Which photos?", origins: {}};
    const mid = {id: "q2", status: "escalated", arbiter: agent("seller"), requester: agent("administrator"), work_id: "w5", reason: "passed", origins: {p: low}};
    const up = {id: "q3", status: "escalated", arbiter: agent("sales"), requester: agent("seller"), work_id: "w1", reason: "passed", origins: {p: mid}};
    const top = {id: "q4", status: "pending", arbiter: human, requester: agent("sales"), work_id: null, reason: "Which photos?", origins: {p: up}};
    const runs = [{id: "r1", agent: "sales", status: "done"}].concat(done ? [] : [{id: "r2", agent: "surgeon", work_id: "about", status: "open", depth: 3}]);
    return Progress.build({works, lanes, runs, runStarts: {r2: 1900}, requests: done ? [] : [low, mid, up, top], rootAgent: "sales", now: 2000});
  };
  const live = agency(false);
  const delivered = agency(true);
  const shape = rows => rows.map(row => "  ".repeat(row.depth) + (row.kind === "fold" ? (row.folded ? "+ " : "- ") + row.key : row.key)).join("\\n");
  const tree = (progress, opened, keep) => Team.rows(progress, opened || {}, keep === undefined ? null : keep);
  """

  defp run!(assertions) do
    assert {"", 0} = GuiModules.run(@modules, @fixtures <> assertions)
  end

  test "the live tree opens the paths at work and asking, the done and the next folded" do
    run!("""
    const rows = tree(live);
    const want = ["front", "  w1", "    + done:w1", "    w5", "      + done:w5", "      about", "      order", "      + next:w5"].join("\\n");
    check(shape(rows) === want, "shape", shape(rows));
    const at = key => rows.find(row => row.key === key);
    check(at("w1").open && at("w1").stem && at("w1").parent === "front" && at("w1").last, "w1", at("w1"));
    check(at("done:w1").text === "2 sub-works done · 5 min · 3 in all · design-lead, language_lawyer" && at("done:w1").count === 2, "done fold", at("done:w1").text);
    check(at("done:w5").text.endsWith(" · toolsmith, surgeon ×2"), "who, by the workflow's first agent", at("done:w5").text);
    check(at("next:w5").text === "2 up next · surgeon ×2" && at("next:w5").last, "next fold", at("next:w5"));
    check(at("order").node.state === "needs-you" && at("about").node.state === "working", "states", "");
    """)
  end

  test "rails carry a line down past the rows of a parent that is not last" do
    run!("""
    const rows = tree(live, {"done:w1": true});
    const at = key => rows.find(row => row.key === key);
    check(shape(rows).startsWith(["front", "  w1", "    - done:w1", "    w2", "    w4", "    w5"].join("\\n")), "unfolded in place", shape(rows));
    check(at("w2").kids === 1 && !at("w2").open && !at("w2").stem && !at("w2").last, "a done work stays folded", at("w2"));
    check(JSON.stringify(at("w1").rails) === "[]" && JSON.stringify(at("w2").rails) === "[false]", "under the last root", [at("w1").rails, at("w2").rails]);
    const opened = tree(live, {"done:w1": true, w2: true});
    const w3 = opened.find(row => row.key === "w3");
    check(w3.depth === 3 && w3.last && JSON.stringify(w3.rails) === "[false,true]", "w2 is not last: its column goes on", w3);
    const root = Team.rows({front: null, roots: live.roots, flat: live.flat}, {}, null);
    check(root[0].key === "w1" && root[0].depth === 0 && root[1].depth === 1 && JSON.stringify(root[1].rails) === "[]", "no front: the roots at the top", shape(root));
    """)
  end

  test "a delivered run shows its roots' works, a holder's three or more folded" do
    run!("""
    const rows = tree(delivered);
    check(shape(rows) === ["front", "  w1", "    w2", "    w4", "    w5"].join("\\n"), "roots open, the rest folded", shape(rows));
    const open = tree(delivered, {w5: true});
    check(shape(open).endsWith(["    w5", "      w6", "      + done:w5:surgeon", "      w7"].join("\\n")), "pages folded at the first's place", shape(open));
    check(open.find(row => row.key === "done:w5:surgeon").text.startsWith("6 sub-works done · "), "pages", "");
    check(open.find(row => row.key === "done:w5:surgeon").text.endsWith(" · surgeon ×6"), "who", "");
    check(tree(delivered, {w1: false}).length === 2, "a root folded by hand", "");
    """)
  end

  test "filters keep the works that match and those above them, all open" do
    run!("""
    const needs = Team.kept(live.flat, "needs-you", "");
    check(Object.keys(needs).sort().join() === "order,w1,w5", "needs you", needs);
    check(shape(tree(live, {w5: false}, needs)) === ["front", "  w1", "    w5", "      order"].join("\\n"), "open through a fold by hand", "");
    const words = Team.kept(live.flat, "all", "design LEAD");
    check(shape(tree(live, {}, words)) === ["front", "  w1", "    w2"].join("\\n"), "by agent, past a fold", Object.keys(words));
    check(Object.keys(Team.kept(live.flat, "all", "gallery")).sort().join() === "gallery,w1,w5", "by title", "");
    check(Object.keys(Team.kept(live.flat, "all", "publish")).sort().join() === "w1,w2,w3", "by stage", "");
    check(Team.kept(live.flat, "all", "  ") === null, "nothing filters", "");
    """)
  end

  test "reveal opens the works above a work and the fold it is in" do
    run!("""
    const opened = Team.reveal(live, {}, "w3");
    check(opened.w1 && opened.w2 && opened["done:w1"] && !opened.w3, "w3", opened);
    check(tree(live, opened).some(row => row.key === "w3"), "w3 shows", shape(tree(live, opened)));
    const shown = Team.reveal(delivered, {}, "about");
    check(tree(delivered, shown).some(row => row.key === "about") && shown["done:w5:surgeon"], "a holder's fold", shown);
    const none = {x: false};
    check(Team.reveal(live, none, "w1") === none, "a root needs nothing", "");
    check(Team.reveal(live, opened, "w3") === opened, "nothing more to open", "");
    """)
  end

  test "step moves through the rows, folds and unfolds, and goes up" do
    run!("""
    const rows = tree(live);
    const at = key => rows.findIndex(row => row.key === key);
    check(JSON.stringify(Team.step(rows, at("w1"), "up")) === "null", "past the front, nothing", "");
    check(Team.step(rows, at("w1"), "down").at === at("done:w1"), "down", "");
    check(JSON.stringify(Team.step(rows, at("done:w1"), "right")) === JSON.stringify({toggle: "done:w1", open: true}), "right unfolds", "");
    check(Team.step(rows, at("w5"), "right").at === at("done:w5"), "right goes to the first row under", "");
    check(JSON.stringify(Team.step(rows, at("w5"), "left")) === JSON.stringify({toggle: "w5", open: false}), "left folds", "");
    check(Team.step(rows, at("about"), "left").at === at("w5"), "left goes to the parent", "");
    check(JSON.stringify(Team.step(rows, at("w1"), "left")) === JSON.stringify({toggle: "w1", open: false}), "left folds a root", "");
    check(Team.step(rows, at("done:w1"), "left").at === at("w1"), "a folded fold goes up", "");
    check(JSON.stringify(Team.step(rows, at("next:w5"), "down")) === "null", "the end", "");
    """)
  end

  test "stages and holder name a workflow's agents" do
    run!("""
    const byWork = Team.index(live.flat);
    check(JSON.stringify(Team.stages(byWork.about)) === JSON.stringify([{agent: "surgeon", status: "current"}, {agent: "copilot", status: "next"}]), "about", "");
    check(JSON.stringify(Team.stages(byWork.home)) === JSON.stringify([{agent: "surgeon", status: "done"}, {agent: "copilot", status: "done"}]), "home", "");
    check(Team.stages(byWork.w1).length === 1 && Team.stages(byWork.w2).length === 0, "one agent, none", "");
    check(byWork.home.agent === "copilot" && Team.holder(byWork.home) === "surgeon" && Team.holder(byWork.w2) === "design-lead", "holder", "");
    check(Team.who([byWork.home, byWork.menu, byWork.w6]) === "surgeon ×2, toolsmith", "who", "");
    """)
  end
end
