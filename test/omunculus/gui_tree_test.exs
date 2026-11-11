defmodule Omunculus.GuiTreeTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @modules ["Requests", "Questions", "Phrases", "Usage", "Time", "Progress", "Tree"]

  # An agency run four levels deep, as the TREE page shows it: sales talks
  # with you; seller's sale (w1) handed down a design preview to design-lead
  # (w2, done, its design work w3 under it) and a question to language_lawyer
  # (w4, done) and the build to administrator (w5), who handed down the
  # toolsmith's set-up (w6, done) and six pages, surgeon then copilot: two
  # done, one working, one asking you through administrator > seller > sales,
  # two up next. `done` is the same run delivered, with the release.
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
  const shape = rows => rows.map(row => "  ".repeat(row.depth) + row.key).join("\\n");
  const tree = (progress, opened, keep) => Tree.rows(progress, opened || {}, keep === undefined ? null : keep);
  const nodes = progress => Object.fromEntries(progress.flat.map(node => [node.work, node]));
  """

  defp run!(assertions) do
    assert {"", 0} = GuiModules.run(@modules, @fixtures <> assertions)
  end

  test "the live tree lists the works in the order they were made, the done folded" do
    run!("""
    const rows = tree(live);
    const want = ["front", "  w1", "    w2", "    w4", "    w5", "      w6", "      home", "      menu", "      about", "      order", "      contact", "      gallery"].join("\\n");
    check(shape(rows) === want, "shape", shape(rows));
    const at = key => rows.find(row => row.key === key);
    check(at("w1").open && at("w1").stem && at("w1").parent === "front" && at("w1").last, "w1", at("w1"));
    check(at("w2").kids === 1 && !at("w2").open && !at("w2").stem && !at("w2").last, "a done work stays folded", at("w2"));
    check(at("order").node.state === "needs-you" && at("about").node.state === "working", "states", "");
    const root = live.roots[0];
    const made = (work, created) => Object.assign({}, root, {work, created, groups: [], children: []});
    const sorted = Tree.rows({front: null, roots: [root, made("late", 5000), made("early", -1)], flat: live.flat}, {w1: false}, null);
    check(sorted.map(row => row.key).join() === "early,w1,late", "roots in creation order", sorted.map(row => row.key));
    """)
  end

  test "rails carry a line down past the rows of a parent that is not last" do
    run!("""
    const rows = tree(live, {w2: true});
    const at = key => rows.find(row => row.key === key);
    check(shape(rows).startsWith(["front", "  w1", "    w2", "      w3", "    w4", "    w5"].join("\\n")), "opened in place", shape(rows));
    check(JSON.stringify(at("w1").rails) === "[]" && JSON.stringify(at("w2").rails) === "[false]", "under the last root", [at("w1").rails, at("w2").rails]);
    check(at("w3").depth === 3 && at("w3").last && JSON.stringify(at("w3").rails) === "[false,true]", "w2 is not last: its column goes on", at("w3"));
    const root = Tree.rows({front: null, roots: live.roots, flat: live.flat}, {}, null);
    check(root[0].key === "w1" && root[0].depth === 0 && root[1].depth === 1 && JSON.stringify(root[1].rails) === "[]", "no front: the roots at the top", shape(root));
    """)
  end

  test "a delivered run shows the roots' works, each folded by itself" do
    run!("""
    const rows = tree(delivered);
    check(shape(rows) === ["front", "  w1", "    w2", "    w4", "    w5"].join("\\n"), "roots open, the rest folded", shape(rows));
    const open = tree(delivered, {w5: true});
    check(shape(open).endsWith(["    w5", "      w6", "      home", "      menu", "      about", "      order", "      contact", "      gallery", "      w7"].join("\\n")), "w5 opened by hand", shape(open));
    check(tree(delivered, {w1: false}).length === 2, "a root folded by hand", "");
    """)
  end

  test "filters keep the works that match and those above them, all open" do
    run!("""
    const needs = Tree.kept(live.flat, "needs-you", "");
    check(Object.keys(needs).sort().join() === "order,w1,w5", "needs you", needs);
    check(shape(tree(live, {w5: false}, needs)) === ["front", "  w1", "    w5", "      order"].join("\\n"), "open through a fold by hand", "");
    const words = Tree.kept(live.flat, "all", "design LEAD");
    check(shape(tree(live, {}, words)) === ["front", "  w1", "    w2"].join("\\n"), "by agent", Object.keys(words));
    check(Object.keys(Tree.kept(live.flat, "all", "gallery")).sort().join() === "gallery,w1,w5", "by title", "");
    check(Object.keys(Tree.kept(live.flat, "all", "publish")).sort().join() === "w1,w2,w3", "by stage", "");
    check(Tree.kept(live.flat, "all", "  ") === null, "nothing filters", "");
    """)
  end

  test "reveal opens the works above a work" do
    run!("""
    const opened = Tree.reveal(live, {}, "w3");
    check(opened.w1 && opened.w2 && !opened.w3, "w3", opened);
    check(tree(live, opened).some(row => row.key === "w3"), "w3 shows", shape(tree(live, opened)));
    const shown = Tree.reveal(delivered, {}, "about");
    check(tree(delivered, shown).some(row => row.key === "about"), "a closed branch", shown);
    const none = {x: false};
    check(Tree.reveal(live, none, "front") === none, "nothing above the front", "");
    check(Tree.reveal(live, opened, "w3") === opened, "nothing more to open", "");
    """)
  end

  test "step moves through the rows, folds and unfolds, and goes up" do
    run!("""
    const rows = tree(live);
    const at = key => rows.findIndex(row => row.key === key);
    check(JSON.stringify(Tree.step(rows, at("w1"), "up")) === "null", "past the front, nothing", "");
    check(Tree.step(rows, at("w1"), "down").at === at("w2"), "down", "");
    check(JSON.stringify(Tree.step(rows, at("w2"), "right")) === JSON.stringify({toggle: "w2", open: true}), "right unfolds", "");
    check(Tree.step(rows, at("w5"), "right").at === at("w6"), "right goes to the first row under", "");
    check(JSON.stringify(Tree.step(rows, at("w5"), "left")) === JSON.stringify({toggle: "w5", open: false}), "left folds", "");
    check(Tree.step(rows, at("about"), "left").at === at("w5"), "left goes to the parent", "");
    check(JSON.stringify(Tree.step(rows, at("w1"), "left")) === JSON.stringify({toggle: "w1", open: false}), "left folds a root", "");
    check(JSON.stringify(Tree.step(rows, at("gallery"), "down")) === "null", "the end", "");
    """)
  end

  test "a work's state names whom it waits for, and its round" do
    run!("""
    const n = nodes(live);
    const say = node => JSON.stringify(Tree.stateOf(node));
    check(Tree.stateOf({state: "waiting", waitingOn: "surgeon, copilot"}).text === "WAITING FOR SURGEON, COPILOT", "a parent waits for its children", "");
    check(say(n.w5) === JSON.stringify({state: "needs-you", text: "WAITING FOR YOU"}), "a parent whose child asks you", say(n.w5));
    check(say(n.about) === JSON.stringify({state: "working", text: "WORKING"}), "working", say(n.about));
    check(say(n.order) === JSON.stringify({state: "needs-you", text: "WAITING FOR YOU"}), "asking you", say(n.order));
    check(say(n.w2) === JSON.stringify({state: "done", text: "DONE"}) && say(n.gallery) === JSON.stringify({state: "up-next", text: "UP NEXT"}), "done, next", "");
    check(Tree.stateOf(Object.assign({}, n.about, {round: 3})).text === "WORKING · ROUND 3", "round", "");
    check(Tree.stateOf({state: "waiting", waitingOn: "a message"}).text === "WAITING FOR A MESSAGE", "a message", "");
    check(Tree.stateOf({state: "waiting", waitingOn: "you"}).state === "needs-you", "a parent of a question for you", "");
    check(Tree.stateOf({state: "failed"}).text === "FAILED" && Tree.stateOf({state: "cancelled"}).text === "CANCELLED", "ends", "");
    check(Tree.frontState({state: "waiting", doing: "Waiting for seller"}).text === "WAITING FOR SELLER" && Tree.frontState({state: "idle", doing: ""}).text === "IDLE", "front", "");
    check(Tree.frontState({state: "working"}).text === "WORKING" && Tree.frontState({state: "needs-you"}).state === "needs-you", "front working", "");
    """)
  end

  test "elapsed is the time it took once done, else since it was made" do
    run!("""
    const n = nodes(live);
    check(Tree.elapsed(n.w2, 9999) === n.w2.finishedIn && n.w2.finishedIn !== null, "done", Tree.elapsed(n.w2, 9999));
    check(Tree.elapsed(n.about, 2000) === 2000 - n.about.created, "open", Tree.elapsed(n.about, 2000));
    check(Tree.elapsed(Object.assign({}, n.w1, {state: "cancelled", finishedIn: null}), 9999) === n.w1.branch.seconds, "cancelled", "");
    check(Tree.frontElapsed(live, 2000) === 2000 && Tree.frontElapsed(null, 2000) === 0 && Tree.frontElapsed({roots: []}, 2000) === 0, "the conversation, while open", Tree.frontElapsed(live, 2000));
    check(Tree.frontElapsed(delivered, 99999) === delivered.roots[0].branch.seconds, "the conversation, once done", Tree.frontElapsed(delivered, 99999));
    """)
  end
end
