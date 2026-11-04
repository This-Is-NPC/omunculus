defmodule Omunculus.GuiCallsTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const check = (ok, what, value) => { if (!ok) throw Error(what + " " + JSON.stringify(value)); };
  const ok = name => ({name, ok: true});
  """

  defp run!(modules, assertions) do
    assert {"", 0} = GuiModules.run(modules, @fixtures <> assertions)
  end

  test "group counts the calls, not hooks or outcomes, folds passed hooks and keeps outcomes as rows" do
    run!(["Phrases", "Calls"], """
    const steps = [
      {name: "read", ok: true, args: {path: "templates/proposal.md"}, output: "", outcome: false},
      {name: "on-continue", ok: true, args: {event: {}}, output: "", outcome: false, hook: true},
      {name: "next_stage", ok: false, args: {}, output: "gate: \\"Price\\" missing", outcome: false},
      {name: "on-notify", ok: true, args: {event: {}}, output: "", outcome: false, hook: true},
      {name: "on-break", ok: false, args: {event: {}}, output: "hook failed", outcome: false, hook: true},
      {name: "edit", ok: true, args: {path: "proposal.md", edits: [{old: "a\\nb", new: "a\\nB\\nc"}]}, output: "", outcome: false},
      {name: "continue", ok: true, text: "moved the work to design", output: "", outcome: true}
    ];
    const out = Calls.group(steps);
    check(out.calls === 3 && out.failed === 1, "counts", out);
    check(out.rows.map(row => row.name).join() === "read,hook,next_stage,on-break,edit,continue", "rows", out.rows.map(row => row.name));
    check(out.rows[0].brief === "templates/proposal.md" && out.rows[0].ok && out.rows[0].diff === null, "read", out.rows[0]);
    check(out.rows[1].hook && out.rows[1].count === 2 && out.rows[1].brief === "2 hooks ran", "hooks", out.rows[1]);
    check(!out.rows[2].ok && out.rows[2].output === 'gate: "Price" missing', "failed", out.rows[2]);
    check(out.rows[3].hook && !out.rows[3].ok && out.rows[3].output === "hook failed", "failed hook", out.rows[3]);
    check(JSON.stringify(out.rows[4].diff) === JSON.stringify({removed: ["a", "b"], added: ["a", "B", "c"]}), "edit diff", out.rows[4].diff);
    check(out.rows[5].outcome && out.rows[5].brief === "moved the work to design" && out.rows[5].diff === null, "outcome", out.rows[5]);
    const one = Calls.group([ok("ls")]);
    check(one.calls === 1 && one.rows[0].brief === "", "one call", one);
    """)
  end

  test "diff reads an edit's spans and a write's first lines" do
    run!(["Phrases", "Calls"], """
    const edit = Calls.diff("edit", {path: "a.css", edits: [{old: "x {\\n}", new: "x {\\n  color: red;\\n}"}, {old: "y", new: ""}]});
    check(JSON.stringify(edit) === JSON.stringify({removed: ["x {", "}", "y"], added: ["x {", "  color: red;", "}"]}), "edit", edit);
    const content = Array.from({length: 25}, (_, i) => "line " + (i + 1)).join("\\n") + "\\n";
    const write = Calls.diff("write", {path: "site/index.html", content});
    check(write.total === 25 && write.added.length === 20 && write.added[0] === "line 1" && write.added[19] === "line 20", "write", write);
    check(JSON.stringify(Calls.diff("write", {path: "e", content: ""})) === JSON.stringify({added: [], total: 0}), "empty write", "");
    check(Calls.diff("read", {path: "a"}) === null && Calls.diff("edit", {path: "a", edits: []}) === null && Calls.diff("edit") === null, "none", "");
    """)
  end

  test "brief names what a tool row is about" do
    run!(["Phrases"], """
    const cases = [
      ["read", {path: "templates/proposal.md", offset: 3}, "templates/proposal.md"],
      ["write", {path: "site/index.html", content: "x"}, "site/index.html"],
      ["edit", {path: "a.css", edits: []}, "a.css"],
      ["ls", {path: "site"}, "site"],
      ["ask", {question: "Which logo?", to: "design-lead"}, "design-lead"],
      ["ask", {question: "Which   logo?\\nThe new one?"}, "Which logo? The new one?"],
      ["escalate", {reason: "r", origins: {}, to: "seller"}, "seller"],
      ["work", {report: "r", works: [{title: "Home page"}, {title: "Menu"}]}, "Home page +1 more"],
      ["grant", {request_id: "q1", name: "write", kind: "tool"}, "q1"],
      ["mystery", {count: 3}, ""]
    ];
    for (const [name, args, shown] of cases) check(Phrases.brief(name, args) === shown, name, Phrases.brief(name, args));
    check(Phrases.brief("read") === "", "no args", "");
    """)
  end

  test "phrase says a running tool and the work it opens" do
    run!(["Phrases"], """
    const titled = {report: "r", works: [{title: "Bakery website", goal: "x"}]};
    const several = {works: [{title: "Bakery website"}, {title: "Menu"}, {title: "About"}]};
    if (Phrases.phrase("work", several) !== "Opening work: Bakery website +2 more") throw Error("several phrase");
    if (Phrases.phrase("work", titled) !== "Opening work: Bakery website" || Phrases.phrase("work", {works: []}) !== "Opening work") throw Error("titled phrase");
    if (Phrases.phrase("read") !== "Reading files" || Phrases.phrase("mystery") !== "Working") throw Error("phrase");
    if (Phrases.did("escalate") !== "Passed a question up" || Phrases.did("mystery") !== "Made a call" || Phrases.did("work", titled) !== "Opened work: Bakery website") throw Error("did");
    if (Phrases.did("ls", {path: "design"}) !== "Looked in design/" || Phrases.did("bash", {command: "cat a/b.md\\nmore"}) !== "Looked at a/b.md" || Phrases.did("bash") !== "Ran a command") throw Error("did folder and command");
    """)
  end

  test "step and stepFailure say a call for the log in plain words" do
    run!(["Phrases"], """
    const same = (got, want) => { if (got !== want) throw Error(got + " != " + want); };
    same(Phrases.step("read", {path: "design/rounds.md"}), "read design/rounds.md");
    same(Phrases.step("read", {}), "read files");
    same(Phrases.step("comment", {body: "Thank you"}), "wrote a note");
    same(Phrases.step("delegate", {agent: "design-lead"}), "handed work down");
    same(Phrases.step("work", {works: [{title: "Bakery website"}]}), "opened work: Bakery website");
    same(Phrases.step("ask", {to: "sales"}), "asked sales");
    same(Phrases.step("mystery", {}), "made a call");
    same(Phrases.stepFailure("read", {path: "design/rounds.md"}), "could not read design/rounds.md");
    same(Phrases.stepFailure("continue", {}), "could not move the work on");
    same(Phrases.stepFailure("mystery", {}), "could not make a call");
    same(Phrases.step("ls", {path: "design"}), "looked in design/");
    same(Phrases.step("ls", {path: "design/"}), "looked in design/");
    same(Phrases.step("ls", {path: "."}), "looked in the project");
    same(Phrases.step("bash", {command: "npx build --prod\\necho done"}), "ran a command");
    same(Phrases.step("bash", {command: "cat design/README.md 2>/dev/null; echo ---; ls -la"}), "looked at design/README.md");
    same(Phrases.step("bash", {command: "ls -la quotes; find quotes -type f | head; cat templates/pr.md"}), "ran a command on quotes/, templates/pr.md");
    same(Phrases.step("bash", {command: "cat quotes/doce-ana.md; echo; grep -n -i 'design\\|preview' quotes/a.md notes.txt"}), "looked at quotes/doce-ana.md, quotes/a.md +1 more");
    same(Phrases.step("bash", {command: "find quotes -type f"}), "looked in quotes/");
    same(Phrases.did("bash", {command: "ls quotes"}), "Looked in quotes/");
    same(Phrases.step("bash", {command: "ls ."}), "looked in the project");
    same(Phrases.step("bash", {command: "cat design/README.md; ls ./"}), "ran a command on design/README.md, the project");
    same(Phrases.stepFailure("bash", {command: "npx build"}), "could not run a command");
    same(Phrases.stepFailure("bash", {command: "rm quotes/a.md"}), "could not run a command on quotes/a.md");
    same(Phrases.stepFailure("bash", {}), "could not run a command");
    const gone = "no such directory: quotes";
    if (!Phrases.missed("ls", gone) || !Phrases.missed("read", "Error: file not found") || Phrases.missed("write", gone) || Phrases.missed("read", "permission denied")) throw Error("missed");
    same(Phrases.miss({path: "quotes"}), "found no quotes yet");
    same(Phrases.miss({}), "found nothing yet");
    same(Phrases.replied("seller", true), "Passed your answers to seller");
    same(Phrases.replied("seller", false), "Answered seller");
    same(Phrases.replied("", false), "Answered");
    """)
  end
end
