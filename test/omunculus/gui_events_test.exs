defmodule Omunculus.GuiEventsTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const check = (ok, what, value) => { if (!ok) throw Error(what + " " + JSON.stringify(value)); };
  const human = {kind: "human", issuer: "local", subject: "1000"};
  const agent = name => ({kind: "agent", agent: name});
  const says = (type, body, who, line) => check(Events.what(type, body, who) === line, type, Events.what(type, body, who));
  """

  defp run!(assertions) do
    assert {"", 0} =
             GuiModules.run(["Model", "Phrases", "Requests", "Events"], @fixtures <> assertions)
  end

  test "requests, escalations and replies say who asks whom what" do
    run!("""
    says("request", {reason: "Which logo?\\nThe new one?", requester: agent("sales"), arbiter: human, options: {}}, "sales", "sales asks you: Which logo?");
    says("request", {reason: "Price?", requester: agent("sales"), arbiter: agent("design-lead")}, "sales", "sales asks design-lead: Price?");
    says("request", {reason: "Go?", requester: human, arbiter: agent("sales")}, "you", "you ask sales: Go?");
    says("escalate", {origins: {design: "55346c4c", copy: "a1"}}, "sales", "passed 2 questions up from design, copy");
    says("escalate", {origins: {design: "55346c4c"}}, "sales", "passed 1 question up from design");
    says("reply", {request_id: "r", option: "approve", body: "approve"}, "you", "chose approve");
    says("reply", {request_id: "r", option: "adjust", body: "darker brown"}, "you", "chose adjust: darker brown");
    says("reply", {request_id: "r", body: "", parts: {design: {body: "", option: "approve"}}}, "you", "chose approve");
    says("reply", {request_id: "r", body: "yes, go"}, "sales", "answered: yes, go");
    """)
  end

  test "tools, hooks and the run's steps read as sentences, never JSON" do
    run!("""
    says("tool", {name: "read", args: {path: "templates/a.md"}, ok: true, output: "x"}, "sales", "read templates/a.md");
    says("tool", {name: "end", via: "escalate", args: {}, ok: true}, "sales", "end, after escalate");
    says("tool", {name: "next_stage", args: {}, ok: false, output: "gate: Price missing\\nmore"}, "sales", "next_stage failed: gate: Price missing");
    says("tool", {name: "on-request", args: {event: {actor_id: "sales"}}, ok: true}, "sales", "on-request hook ran");
    says("tool", {name: "on-break", args: {event: {}}, ok: false, output: "exit 1"}, "harness", "on-break hook failed: exit 1");
    check(Events.hook({args: {event: {}}}) && !Events.hook({args: {event: {}, path: "a"}}) && !Events.hook({}), "hook", "");
    says("end", {}, "sales", "ended");
    says("end-run", {}, "harness", "run ended");
    says("end-run", {error: "timeout\\ntrace"}, "harness", "run failed: timeout");
    says("start-run", {agent: "sales", depth: 1}, "sales", "sales starts at level 1");
    says("continue", {from: "qualify", to: "design"}, "sales", "moved on from qualify to design");
    says("continue", {from: "build", to: null, parent_id: null}, "sales", "finished at build");
    says("reopen", {parent_id: "p", stage: "design"}, "sales", "sent back to design");
    says("break", {body: "no price\\nat all"}, "sales", "stopped: no price");
    says("delegate", {title: "Logo", goal: "g", parent_id: "p"}, "sales", "handed down: Logo");
    says("work", {works: [{title: "Bakery"}, {title: "Menu"}], start: true}, "sales", "opened Bakery +1 more");
    says("work", {state: "open", reason: "reopened_by_prompt"}, "", "reopened by a message");
    says("grant", {name: "bash", kind: "tool"}, "you", "granted bash for this work");
    says("attach", {attachments: [{}, {}]}, "sales", "attached 2 files");
    says("comment.delete", {ids: ["a"]}, "sales", "deleted 1 comment");
    says("inbox.read", {inbox_id: "i"}, "sales", "read a notice");
    says("session.open", {}, "", "session open");
    """)
  end

  test "model replies show their text, or what they call" do
    run!("""
    says("model", {content: "Hello\\n\\nthere"}, "sales", "Hello there");
    says("model", {content: [{type: "tool_use", name: "read"}, {type: "tool_use", name: "ls"}]}, "sales", "calls 2 tools");
    says("model", {choices: [{message: {content: null, tool_calls: [{}]}}]}, "sales", "calls 1 tool");
    says("model", {usage: {}}, "sales", "replied without text");
    """)
  end
end
