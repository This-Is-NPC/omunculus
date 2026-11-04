defmodule Omunculus.GuiShortcutsTest do
  use ExUnit.Case, async: true

  defp run(assertions) do
    script =
      File.read!(Path.expand("../../apps/kit/client/Shortcuts.js", __DIR__))
      |> String.replace(".pragma library", "")

    assert {"", 0} = System.cmd("deno", ["eval", script <> assertions], stderr_to_stdout: true)
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
    if (chord("reply") !== "Alt+R" || label("page") !== "1 · 2 · …") throw Error("lookups");
    if (rows("team").length === 0) throw Error("rows");
    if (chord("projects") !== "Ctrl+P" || find("projects").mutates) throw Error("projects");
    if (keys("start-projects")[0] !== "P" || find("start-projects").tier !== 1) throw Error("start-projects");
    """)
  end
end
