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
end
