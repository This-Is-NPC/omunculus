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
end
