defmodule Omunculus.GuiRequestsTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const human = {kind: "human", issuer: "local", subject: "1000"};
  const agent = name => ({kind: "agent", agent: name});
  """

  defp run!(modules, assertions) do
    assert {"", 0} = GuiModules.run(modules, @fixtures <> assertions)
  end

  test "pending, human, answer and label use participant-neutral fields" do
    run!(["Requests"], """
    const owner = {kind: "human", issuer: "local", subject: "1000"};
    const requests = [
      {status: "pending", arbiter: agent("worker")}, {status: "pending", arbiter: owner},
      {status: "closed", arbiter: owner}, {status: "escalated", arbiter: agent("worker")}
    ];
    if (requests.filter(Requests.pending).length !== 2) throw Error("pending requests missing");
    if (requests.filter(r => Requests.pending(r) && Requests.human(r.arbiter)).length !== 1) throw Error("human count");
    if (JSON.stringify(Requests.answer("", "Logo attached")) !== JSON.stringify({body: "Logo attached"}))
      throw Error("text replies must omit option");
    if (JSON.stringify(Requests.answer("approve", "")) !== JSON.stringify({body: "approve", option: "approve"}))
      throw Error("decision replies must retain option");
    if (Requests.label(agent("worker")) !== "worker" || Requests.label(owner) !== "local:1000") throw Error("participant label");
    """)
  end

  test "contained hides the lower requests of a climb; kind and chain" do
    run!(["Requests"], """
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

  test "holder follows a question up its climb; works are where it climbed from" do
    run!(["Requests"], """
    const low = {id: "a", status: "escalated", arbiter: agent("lead"), requester: agent("designer"), work_id: "w3", origins: {}};
    const mid = {id: "b", status: "escalated", arbiter: agent("seller"), requester: agent("lead"), work_id: "w2", origins: {p: low}};
    const top = {id: "c", status: "pending", arbiter: human, requester: agent("sales"), work_id: null, origins: {q: mid}};
    const loose = {id: "d", status: "escalated", arbiter: agent("seller"), requester: agent("lead"), work_id: "w2", origins: {}};
    const done = {id: "e", status: "closed", arbiter: human, requester: agent("sales"), work_id: "w1"};
    const all = [low, mid, top, loose, done];
    if (Requests.holder(low, all) !== top || Requests.holder(mid, all) !== top || Requests.holder(top, all) !== top)
      throw Error("holder of the climb");
    if (Requests.holder(loose, all) !== null || Requests.holder(done, all) !== null) throw Error("no holder");
    if (Requests.works(top).join() !== "w2,w3") throw Error("works " + Requests.works(top));
    if (Requests.works(done).join() !== "w1" || Requests.works(loose).join() !== "w2") throw Error("own work");
    """)
  end
end
