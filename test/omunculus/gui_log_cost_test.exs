defmodule Omunculus.GuiLogCostTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @modules ["Requests", "Questions", "Phrases", "Usage", "Time", "Progress", "Tree", "LogGroups"]

  # A front agent over one root work (pm) with two works under it (seller and
  # designer), as the server's usage prices them.
  @fixtures """
  const check = (ok, what, value) => { if (!ok) throw Error(what + " " + JSON.stringify(value)); };
  const node = (work, parent, level, agent, kids) =>
    ({work, parent, level, agent, title: work, state: "working", created: level, steps: [], groups: [{nodes: kids}]});
  const seller = node("w2", "w1", 1, "seller", []);
  const designer = node("w3", "w1", 1, "designer", []);
  seller.created = 1; designer.created = 2;
  const pm = node("w1", "", 0, "pm", [seller, designer]);
  const progress = {front: {agent: "front", state: "idle", doing: ""}, roots: [pm], flat: [pm, seller, designer]};
  const line = (id, work, who) => ({id, work, who, time: "10:00:00", kind: "step", what: id, ok: true, minor: false, retried: false, request: "", head: "", day: ""});
  const lines = [line("a", "", "front"), line("b", "w1", "pm"), line("c", "w2", "seller"), line("d", "w3", "designer"), line("e", "w2", "seller")];
  """

  defp run!(assertions) do
    assert {"", 0} = GuiModules.run(@modules, @fixtures <> assertions)
  end

  test "the log groups its lines under the level of their work, front agent first" do
    run!("""
    const items = LogGroups.group("level", lines, progress);
    check(items.map(item => item.kind === "level" ? item.text : item.line.id + item.col).join("|")
      === "LEVEL 0  \\u00b7  front  \\u00b7  1 event|a0|LEVEL 1  \\u00b7  pm  \\u00b7  1 event|b1|LEVEL 2  \\u00b7  seller, designer  \\u00b7  3 events|c2|d2|e2", "levels", items);
    check(LogGroups.group("time", lines, progress).every(item => item.kind === "line" && item.col === -1), "time has no marks", 0);
    """)
  end

  test "the log groups its lines under their work, in the order of the tree" do
    run!("""
    const items = LogGroups.group("work", lines, progress);
    check(items.map(item => item.kind === "work" ? item.row.key + ":" + item.count : item.line.id).join(",") === "front:1,a,w1:1,b,w2:2,c,e,w3:1,d", "order", items);
    const c = items.find(item => item.kind === "line" && item.line.id === "c");
    check(c.col === 3 && JSON.stringify(c.rails) === "[false,true]" && c.through === false, "c hangs under w2", c);
    const b = items.find(item => item.kind === "line" && item.line.id === "b");
    check(b.col === 2 && b.through === true, "b hangs under w1, which has works below", b);
    const loose = LogGroups.group("work", lines, {front: null, roots: [pm], flat: pm.groups[0].nodes.concat([pm])});
    check(loose[0].kind === "level" && loose[0].text === "NO WORK  \\u00b7  1 event", "lines of no work, with no front agent", loose[0]);
    """)
  end

  test "the cost's works carry the server's dollars, their models and their branch's share" do
    run!("""
    const rows = Tree.rows(progress, {w1: true}, null);
    const entry = (usd, models) => Object.assign({}, {replies: 1, input: 10, cached: 0, output: 5, usd, models, unpriced: []});
    const call = (model, usd) => ({model, usd, fresh: 10, cache_write: 0, cached: 0, output: 5});
    const found = Usage.byWork(rows, Usage.spend({
      agents: [],
      works: [
        {work: "", own: entry(0.5, ["m-0"]), branch: entry(0.5, ["m-0"]), calls: []},
        {work: "w1", own: entry(null, []), branch: entry(1.5, ["m-1", "m-2"]), calls: []},
        {work: "w3", own: entry(1, ["m-1"]), branch: entry(1, ["m-1"]), calls: [call("m-1", 0.25), call("m-1", 0.75)]}
      ],
      total: {usd: 2, models: ["m-0", "m-1", "m-2"], unpriced: []}
    }));
    check(found.map(each => each.agent).join() === "front,pm,seller,designer", "agents", found);
    check(found[0].own.usd === 0.5 && found[0].branch.usd === 2 && found[0].share === 1, "the front's own are the calls of no work, its branch is all", found[0]);
    check(found[1].own.usd === null && found[1].share === 0.75, "pm 1.5 of 2", found[1]);
    check(found[2].own.models.length === 0 && found[2].share === 0 && found[2].calls.length === 0, "seller used nothing", found[2]);
    check(found[3].own.models[0] === "m-1" && found[3].calls[1].usd === 0.75 && found[3].share === 0.5, "designer", found[3]);
    const none = Usage.byWork(rows, Usage.spend(null));
    check(none.length === 4 && none.every(each => each.share === 0), "nothing used", none);
    """)
  end
end
