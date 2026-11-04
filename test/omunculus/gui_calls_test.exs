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
