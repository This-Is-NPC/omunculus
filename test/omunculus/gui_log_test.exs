defmodule Omunculus.GuiLogTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const expect = (got, want, what) => { if (got !== want) throw Error(what + ": " + JSON.stringify(got) + " != " + JSON.stringify(want)); };
  """

  test "a text cut for room ends at a word, not in the middle of one" do
    script =
      @fixtures <>
        """
        expect(Words.atWord("get online soon", "get online soon"), "get online soon", "fits");
        expect(Words.atWord("get online soon", "get onl\\u2026"), "get\\u2026", "mid-word");
        expect(Words.atWord("get online soon", "get online\\u2026"), "get online\\u2026", "on a word end");
        expect(Words.atWord("get online soon", "get \\u2026"), "get\\u2026", "after a space");
        expect(Words.atWord("one, two three", "one, tw\\u2026"), "one\\u2026", "punctuation goes with the cut");
        expect(Words.atWord("extraordinarily long", "extraord\\u2026"), "extraord\\u2026", "a single word stays cut");
        expect(Words.atWord("short", ""), "", "nothing to show stays so");
        """

    assert {"", 0} = GuiModules.run(["Words"], script)
  end

  test "the log's chips count what asks, failed and is plumbing among every row" do
    script =
      @fixtures <>
        """
        const rows = [
          {request: "q1", ok: true, retried: false, minor: false, head: ""},
          {request: "", ok: false, retried: false, minor: false, head: ""},
          {request: "", ok: false, retried: true, minor: false, head: ""},
          {request: "", ok: true, retried: false, minor: true, head: ""},
          {request: "", ok: true, retried: false, minor: true, head: "DESIGNER \\u00b7 run 1"},
          {request: "q2", ok: true, retried: false, minor: false, head: ""}
        ];
        const found = Events.tally(rows.length, index => rows[index], line => line.request === "q1");
        expect(JSON.stringify(found), '{"asks":1,"failed":1,"minor":1}', "counts");
        expect(JSON.stringify(Events.tally(0, () => null, () => false)), '{"asks":0,"failed":0,"minor":0}', "empty");
        """

    assert {"", 0} =
             GuiModules.run(["Model", "Phrases", "Requests", "Questions", "Events"], script)
  end
end
