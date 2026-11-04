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
             GuiModules.run(
               ["Model", "Phrases", "Requests", "Questions", "Events"],
               @fixtures <> assertions
             )
  end

  test "requests, escalations and replies say who asks whom what" do
    run!("""
    says("request", {reason: "Which logo?\\nThe new one?", requester: agent("sales"), arbiter: human, options: {}}, "sales", "sales asks you: Which logo?");
    says("request", {reason: "Price?", requester: agent("sales"), arbiter: agent("design-lead")}, "sales", "sales asks design-lead: Price?");
    says("request", {reason: "Go?", requester: human, arbiter: agent("sales")}, "you", "you ask sales: Go?");
    says("request", {reason: "Intro\\n\\n1. Name?\\n2. Price?\\n3. Date?", requester: agent("sales"), arbiter: human}, "sales", "sales asks you 3 questions: Intro");
    check(Events.questions("1. a\\n2. b") === 2 && Events.questions("Which logo?") === 1, "questions", "");
    check(Events.what("escalate", {origins: {design: "r1", copy: "r2"}}, "sales", {r1: 5}) === "passed 6 questions up", "escalate", "");
    says("escalate", {origins: {design: "55346c4c"}}, "sales", "passed 1 question up");
    says("reply", {request_id: "r", option: "approve", body: "approve"}, "you", "chose approve");
    says("reply", {request_id: "r", option: "adjust", body: "darker brown"}, "you", "chose adjust: darker brown");
    says("reply", {request_id: "r", body: "", parts: {design: {body: "", option: "approve"}}}, "you", "chose approve");
    says("reply", {request_id: "r", body: "yes, go"}, "sales", "answered: yes, go");
    """)
  end

  test "tools, hooks and the run's steps read as sentences, never JSON" do
    run!("""
    says("tool", {name: "read", args: {path: "templates/a.md"}, ok: true, output: "x"}, "sales", "read templates/a.md");
    says("tool", {name: "end", via: "escalate", args: {}, ok: true}, "sales", "finished after passing up");
    says("tool", {name: "next_stage", args: {}, ok: false, output: "gate: Price missing\\nmore"}, "sales", "next_stage failed: gate: Price missing");
    says("tool", {name: "on-request", args: {event: {actor_id: "sales"}}, ok: true}, "sales", "on-request hook ran");
    says("tool", {name: "on-break", args: {event: {}}, ok: false, output: "exit 1"}, "harness", "on-break hook failed: exit 1");
    check(Events.hook({args: {event: {}}}) && !Events.hook({args: {event: {}, path: "a"}}) && !Events.hook({}), "hook", "");
    says("end", {}, "sales", "finished");
    says("end-run", {}, "harness", "run finished");
    says("end-run", {error: "timeout\\ntrace"}, "harness", "run failed: timeout");
    says("start-run", {agent: "sales", depth: 1}, "sales", "sales started");
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

  test "plumbing is minor and every kind has its word" do
    run!("""
    const minor = (type, body) => Events.minor(type, body);
    check(minor("start-run", {}) && minor("end-run", {}) && !minor("end-run", {error: "x"}), "runs", "");
    check(minor("tool", {name: "on-request", args: {event: {}}, ok: true}) && !minor("tool", {name: "on-request", args: {event: {}}, ok: false}), "hook", "");
    check(minor("tool", {name: "end", args: {}, ok: true}) && !minor("tool", {name: "read", args: {path: "a"}, ok: true}), "tool", "");
    check(minor("model", {usage: {}}) && !minor("model", {content: "Hi"}), "model", "");
    check(!minor("request", {}) && !minor("escalate", {}) && !minor("prompt", {}), "news", "");
    check(Events.kind("request", {}) === "question" && Events.kind("tool", {args: {event: {}}}) === "hook" && Events.kind("tool", {args: {path: "a"}}) === "step" && Events.kind("start-run", {}) === "run" && Events.kind("escalate", {}) === "passed up", "kind", "");
    """)
  end

  test "model replies show their text, or what they call" do
    run!("""
    says("model", {content: "Hello\\n\\nthere"}, "sales", "Hello there");
    says("model", {content: [{type: "tool_use", name: "read"}, {type: "tool_use", name: "ls"}]}, "sales", "planned 2 steps");
    says("model", {choices: [{message: {content: null, tool_calls: [{}]}}]}, "sales", "planned 1 step");
    says("model", {usage: {}}, "sales", "had nothing to add");
    """)
  end
end
