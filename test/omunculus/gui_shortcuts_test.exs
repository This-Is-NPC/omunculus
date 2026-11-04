defmodule Omunculus.GuiShortcutsTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  # The bare keys the window may answer to, pure navigation, and whether a
  # key sequence is a single key with no Ctrl, Alt or Meta.
  @fixtures """
  const bareKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "/", "[", "]", "?", "F1", "Esc", "N", "H", "B", "P"];
  const isBare = sequence => !/^(Ctrl|Alt|Meta)\\+/.test(sequence);
  const table = Shortcuts.table;
  """

  defp run(assertions) do
    assert {"", 0} = GuiModules.run(["Shortcuts"], @fixtures <> assertions)
  end

  test "no action that changes something has a bare key" do
    run("""
    for (const entry of table) {
      if (entry.mutates && entry.keys.some(isBare))
        throw Error(entry.id + " changes something yet has a bare key");
      if (entry.tier === 0 && entry.keys.length > 0)
        throw Error(entry.id + " is tier 0 yet has a key");
    }
    if (!table.some(entry => entry.mutates && entry.tier === 0)) throw Error("no tier 0 action");
    """)
  end

  test "every bare key is a navigation key of the whitelist" do
    run("""
    for (const entry of table) {
      for (const key of entry.keys) {
        if (isBare(key) && !bareKeys.includes(key)) throw Error(entry.id + ": " + key + " is not navigation");
        if (entry.tier === 1 && !isBare(key)) throw Error(entry.id + ": " + key + " is not bare");
        if (entry.tier === 2 && !/^(Ctrl|Alt)\\+/.test(key)) throw Error(entry.id + ": " + key + " is not a chord");
      }
    }
    """)
  end

  test "ids are unique and lookups read the table" do
    run("""
    const ids = table.map(entry => entry.id);
    if (new Set(ids).size !== ids.length) throw Error("duplicate id");
    if (Shortcuts.chord("reply") !== "Alt+R" || Shortcuts.label("page") !== "1 · 2 · …") throw Error("lookups");
    if (Shortcuts.rows("team").length === 0) throw Error("rows");
    if (Shortcuts.rows("everywhere")[0][0] !== "1 · 2 · …") throw Error("rows label");
    if (Shortcuts.chord("projects") !== "Ctrl+P" || Shortcuts.find("projects").mutates) throw Error("projects");
    if (Shortcuts.keys("start-projects")[0] !== "P" || Shortcuts.find("start-projects").tier !== 1) throw Error("start-projects");
    """)
  end
end
