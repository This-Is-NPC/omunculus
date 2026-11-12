defmodule Omunculus.GuiLogCostTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @modules ["Requests", "Questions", "Phrases", "Usage", "Time", "Progress", "Tree", "LogGroups"]

  # A front agent over one root work (pm) with two works under it (seller and
  # designer), the designer's having run on a model; tokens as tallies.
  @fixtures """
  const check = (ok, what, value) => { if (!ok) throw Error(what + " " + JSON.stringify(value)); };
  const tally = (input, output) => Object.assign(Usage.tally(), {calls: 1, input, output});
  const node = (work, parent, level, agent, own, kids) => {
    const made = {work, parent, level, agent, title: work, state: "working", created: level, steps: [], groups: [{nodes: kids}],
      own: {usage: own}, branch: {usage: own}};
    return made;
  };
  const seller = node("w2", "w1", 1, "seller", tally(10, 5), []);
  const designer = node("w3", "w1", 1, "designer", tally(20, 5), []);
  seller.created = 1; designer.created = 2;
  const pm = node("w1", "", 0, "pm", tally(30, 10), [seller, designer]);
  pm.branch = {usage: tally(60, 20)};
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

  test "the cost's works carry their agent's model and their branch's share of the tokens" do
    run!("""
    const rows = Tree.rows(progress, {w1: true}, null);
    const all = tally(100, 20);
    const found = Usage.byWork(rows, {"": tally(40, 0)}, all, {designer: {model: "m-1"}});
    check(found.map(each => each.agent).join() === "front,pm,seller,designer", "agents", found);
    check(found[0].own.input === 40 && found[0].share === 1, "the front's own are the calls of no work, its branch is all", found[0]);
    check(found[1].share === 80 / 120 && found[1].model === "", "pm 80 of 120, no model known", found[1]);
    check(found[3].model === "m-1" && found[3].own.input === 20 && found[3].share === 25 / 120, "designer", found[3]);
    check(Usage.byWork([], {}, tally(0, 0), {}).length === 0 && Usage.byWork(rows, {}, tally(0, 0), {})[1].share === 0, "nothing used", 0);
    """)
  end
end
