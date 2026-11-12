defmodule Omunculus.GuiArtifactsTest do
  use ExUnit.Case, async: true

  test "an artifact reads by its title and what it is, never its id or media type" do
    script = """
    const check = (got, want) => { if (got !== want) throw Error(JSON.stringify(got) + " != " + JSON.stringify(want)); };
    const hash = "0023b19cb2ea27323f5f6d8b3443cbe4";
    check(Phrases.document("proposal-" + hash), "Proposal");
    check(Phrases.document("proposal-" + hash + ".md"), "Proposal");
    check(Phrases.document("menu_prices.json"), "Menu prices");
    check(Phrases.document("design-brief"), "Design brief");
    check(Phrases.said("put_artifact", {name: "proposal-" + hash + ".md", content: "x"}), "Saved Proposal");
    check(Phrases.said("get_artifact", {name: "menu_prices.json"}), "Read Menu prices");
    check(Artifacts.format("application/json"), "data");
    check(Artifacts.format("text/markdown"), "document");
    check(Artifacts.format("image/png"), "image");
    check(Artifacts.format("application/x-thing"), "file");
    check(Artifacts.heading({name: "proposal-" + hash, kind: "proposal", versions: [{media_type: "application/json"}]}), "Proposal  \\u00b7  data");
    check(Artifacts.heading({name: "site-copy", kind: "copy", versions: [{media_type: "text/markdown"}]}), "Site copy  \\u00b7  copy  \\u00b7  document");
    check(Artifacts.heading({name: "proposal-" + hash + ".md", kind: "document", versions: [{media_type: "text/markdown"}]}), "Proposal  \\u00b7  document");
    check(Artifacts.heading({name: "", kind: "note", versions: []}), "note");
    """

    assert {"", 0} = Omunculus.GuiModules.run(["Phrases", "Artifacts"], script)
  end

  test "files hang under the work that wrote them, in the tree's order" do
    script = """
    const check = (got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) throw Error(JSON.stringify(got) + " != " + JSON.stringify(want)); };
    const human = {kind: "human", issuer: "local", subject: "1000"};
    const iso = t => new Date(t * 1000).toISOString();
    const works = [["w1", null, "seller"], ["w2", "w1", "designer"], ["w3", "w1", "writer"]].map(([id, parent, assignee], i) =>
      ({id, title: id, parent_id: parent, assignee, state: "done", created_at: iso(i * 100), updated_at: iso(i * 100 + 50)}));
    const progress = Progress.build({me: human, works, lanes: {}, runs: [{id: "r1", agent: "sales", status: "done"}], runStarts: {}, requests: [], rootAgent: "sales", now: 1000});
    const version = (name, number, work) => ({name, version: {version: number, work_id: work}});
    const versions = [version("brief.md", 1, null), version("a.md", 1, "w2"), version("a.md", 2, "w2"), version("b.md", 1, "w2"), version("c.md", 1, "gone")];

    // The work that wrote files and the work above it; w3 wrote none.
    check(Object.keys(Artifacts.kept(progress.flat, versions)).sort(), ["w1", "w2"]);

    const rows = Tree.rows(progress, {}, Artifacts.kept(progress.flat, versions));
    const items = Artifacts.byWork(rows, versions);
    check(items.map(item => item.kind + ":" + item.key), [
      "work:front", "file:front:brief.md", "work:w1", "work:w2", "file:w2:a.md", "file:w2:b.md", "loose:loose:c.md"]);
    // A work shows the latest version it wrote of a name.
    check(items.filter(item => item.kind === "file").map(item => item.version.version), [1, 2, 1]);
    check(items.filter(item => item.kind === "work").map(item => item.files), [1, 0, 2]);
    // The lifeline goes on while works follow, and ends at a work's last file.
    check(items.filter(item => item.kind === "file").map(item => item.last), [false, false, true]);
    check(Artifacts.byWork(rows, []), []);
    """

    assert {"", 0} =
             Omunculus.GuiModules.run(
               [
                 "Requests",
                 "Questions",
                 "Phrases",
                 "Usage",
                 "Time",
                 "Progress",
                 "Pending",
                 "Tree",
                 "Artifacts"
               ],
               script
             )
  end
end
