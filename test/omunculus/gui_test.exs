defmodule Omunculus.GuiTest do
  use ExUnit.Case, async: true

  test "GUI request filtering and receiver labels use participant-neutral fields" do
    script =
      File.read!(Path.expand("../../gui/Requests.js", __DIR__))
      |> String.replace(".pragma library", "")

    assertions = """
    const agent = {kind: "agent", agent: "worker"};
    const owner = {kind: "human", issuer: "local", subject: "1000"};
    const requests = [
      {status: "pending", arbiter: agent}, {status: "pending", arbiter: owner},
      {status: "closed", arbiter: owner}, {status: "escalated", arbiter: agent}
    ];
    if (requests.filter(pending).length !== 2) throw Error("pending requests missing");
    if (requests.filter(r => pending(r) && human(r.arbiter)).length !== 1) throw Error("human count");
    if (JSON.stringify(answer("", "Logo attached")) !== JSON.stringify({body: "Logo attached"}))
      throw Error("text replies must omit option");
    if (JSON.stringify(answer("approve", "")) !== JSON.stringify({body: "approve", option: "approve"}))
      throw Error("decision replies must retain option");
    if (label(agent) !== "worker" || label(owner) !== "local:1000") throw Error("participant label");
    """

    assert {"", 0} = System.cmd("deno", ["eval", script <> assertions], stderr_to_stdout: true)
  end
end
