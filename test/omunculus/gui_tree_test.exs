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
    return Progress.build({me: human, works, lanes, runs, runStarts: {r2: 1900}, requests: done ? [] : [low, mid, up, top], rootAgent: "sales", now: 2000});
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

  test "the chart puts each work in the band of its level, a parent over its works" do
    run!("""
    const chart = Tree.chart(live);
    const cell = key => chart.cells.find(each => each.key === key);
    check(chart.levels === 4 && chart.cells.length === live.flat.length + 2, "four levels, every work, you and the front", chart.levels);
    check(cell("front").level === 0 && cell("you").level === 0 && cell("w1").level === 1 && cell("w3").level === 3 && cell("order").level === 3, "levels", "");
    check(chart.side.from === "you" && chart.side.to === "front" && cell("you").col < cell("front").col, "you beside the front", chart.side);
    const kids = chart.links.find(link => link.from === "w5").to;
    check(kids.length === 7 && cell("w5").col === (cell(kids[0]).col + cell(kids[kids.length - 1]).col) / 2, "a parent is centred over its works", kids);
    check(chart.cells.every(each => each.col >= 0 && chart.cells.filter(other => other.level === each.level && other.col === each.col).length === 1), "no two nodes share a place", "");
    check(Tree.chart(null).cells.length === 0, "nothing to draw", "");
    check(Tree.chart(delivered).brackets.length === 0, "no parallel works once all is done", Tree.chart(delivered).brackets);
    """)
  end
end
