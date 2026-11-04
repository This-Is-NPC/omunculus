defmodule Omunculus.GuiCallsTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const check = (ok, what, value) => { if (!ok) throw Error(what + " " + JSON.stringify(value)); };
  const ok = name => ({name, ok: true});
  const bad = name => ({name, ok: false});
  """

  defp run!(modules, assertions) do
    assert {"", 0} = GuiModules.run(modules, @fixtures <> assertions)
  end

  test "group counts every call, folds passed hooks and keeps outcomes as rows" do
    run!(["Phrases", "Calls"], """
    const steps = [
      {name: "read", ok: true, args: {path: "templates/proposal.md"}, output: "", outcome: false, at: 10},
      {name: "on-continue", ok: true, args: {event: {}}, output: "", outcome: false, hook: true, at: 12},
      {name: "next_stage", ok: false, args: {}, output: "gate: \\"Price\\" missing", outcome: false, at: 20},
      {name: "on-notify", ok: true, args: {event: {}}, output: "", outcome: false, hook: true, at: 25},
      {name: "on-break", ok: false, args: {event: {}}, output: "hook failed", outcome: false, hook: true, at: 30},
      {name: "edit", ok: true, args: {path: "proposal.md", edits: [{old: "a\\nb", new: "a\\nB\\nc"}]}, output: "", outcome: false, at: 40},
      {name: "continue", ok: true, text: "moved the work to design", output: "", outcome: true, at: 52}
    ];
    const out = Calls.group(steps);
    check(out.calls === 6 && out.failed === 2 && out.seconds === 42, "counts", out);
    check(out.rows.map(row => row.name).join() === "read,hook,next_stage,on-break,edit,continue", "rows", out.rows.map(row => row.name));
    check(out.rows[0].brief === "templates/proposal.md" && out.rows[0].ok && out.rows[0].diff === null, "read", out.rows[0]);
    check(out.rows[1].hook && out.rows[1].count === 2 && out.rows[1].brief === "2 hooks ran", "hooks", out.rows[1]);
    check(!out.rows[2].ok && out.rows[2].output === 'gate: "Price" missing', "failed", out.rows[2]);
    check(out.rows[3].hook && !out.rows[3].ok && out.rows[3].output === "hook failed", "failed hook", out.rows[3]);
    check(JSON.stringify(out.rows[4].diff) === JSON.stringify({removed: ["a", "b"], added: ["a", "B", "c"]}), "edit diff", out.rows[4].diff);
    check(out.rows[5].outcome && out.rows[5].brief === "moved the work to design" && out.rows[5].diff === null, "outcome", out.rows[5]);
    const untimed = Calls.group([ok("ls")]);
    check(untimed.seconds === undefined && untimed.calls === 1 && untimed.rows[0].brief === "", "untimed", untimed);
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

  test "summarize speaks in phrases and counts every failure" do
    run!(["Phrases"], """
    const read6 = Array.from({length: 6}, () => ok("read"));
    let out = Phrases.summarize(read6.concat([ok("write")]));
    if (out.text !== "Read 6 files, wrote a file" || out.failed !== 0 || out.failedText !== "") throw Error(out.text);
    out = Phrases.summarize([ok("read"), bad("write"), bad("edit"), ok("read")]);
    if (out.text !== "Read 2 files") throw Error(out.text);
    if (out.failed !== 2 || out.failedText !== "2 attempts did not work") throw Error(JSON.stringify(out));
    out = Phrases.summarize([bad("next_stage"), ok("ls")]);
    if (out.failed !== 1 || out.failedText !== "1 attempt did not work" || out.text !== "Looked at the project" || "hidden" in out) throw Error(JSON.stringify(out));
    out = Phrases.summarize(Array.from({length: 4}, () => bad("next_stage")));
    if (out.failed !== 4 || out.failedText !== "4 attempts did not work") throw Error(JSON.stringify(out));
    if (Phrases.summarize([ok("mystery")]).text !== "Worked") throw Error("unknown");
    const titled = {name: "work", ok: true, args: {report: "r", works: [{title: "Bakery website", goal: "x"}]}};
    const several = {name: "work", ok: true, args: {works: [{title: "Bakery website"}, {title: "Menu"}, {title: "About"}]}};
    if (Phrases.phrase("work", several.args) !== "Opening work: Bakery website +2 more") throw Error("several phrase");
    if (Phrases.summarize([several]).text !== "Opened work: Bakery website +2 more") throw Error("several summary");
    if (Phrases.phrase("work", titled.args) !== "Opening work: Bakery website" || Phrases.phrase("work", {works: []}) !== "Opening work") throw Error("titled phrase");
    if (Phrases.summarize([titled]).text !== "Opened work: Bakery website") throw Error("titled summary");
    if (Phrases.summarize([titled, titled]).text !== "Opened 2 pieces of work") throw Error("titled many");
    if (Phrases.summarize([ok("work")]).text !== "Opened some work") throw Error("untitled summary");
    if (Phrases.phrase("read") !== "Reading files" || Phrases.phrase("mystery") !== "Working") throw Error("phrase");
    """)
  end
end
