defmodule Omunculus.GuiBreakpointsTest do
  use ExUnit.Case, async: true

  test "sizes, margins, targets and indents change at 420, 700 and 1100" do
    script = """
    const expect = (got, want, what) => { if (got !== want) throw Error(what + ": " + got + " != " + want); };
    const at = { 360: "narrow", 419: "narrow", 699: "narrow", 700: "medium", 1099: "medium", 1100: "wide", 1280: "wide" };
    for (const width in at) expect(Breakpoints.size(Number(width)), at[width], "size " + width);
    expect(Breakpoints.tight(419), true, "tight 419");
    expect(Breakpoints.tight(420), false, "tight 420");
    [[360, 8], [420, 10], [699, 10], [700, 16], [1099, 16], [1100, 20]]
      .forEach(([width, margin]) => expect(Breakpoints.margin(width), margin, "margin " + width));
    [[699, 44], [700, 28], [1280, 28]].forEach(([width, target]) => expect(Breakpoints.target(width), target, "target " + width));
    [[699, 12], [700, 16]].forEach(([width, indent]) => expect(Breakpoints.indent(width), indent, "indent " + width));
    """

    assert {"", 0} = Omunculus.GuiModules.run(["Breakpoints"], script)
  end

  test "room is the parent's width, unless the parent takes it from its children or has none" do
    script = """
    const expect = (got, want, what) => { if (got !== want) throw Error(what + ": " + got + " != " + want); };
    expect(Breakpoints.room(null), Infinity, "no parent");
    expect(Breakpoints.room({ width: 300 }), 300, "item");
    expect(Breakpoints.room({ width: 0 }), Infinity, "item without a width");
    expect(Breakpoints.room({ width: 300, populate: null, flow: 0, layoutDirection: 0 }), 300, "flow");
    expect(Breakpoints.room({ width: 300, populate: null, layoutDirection: 0 }), Infinity, "row");
    expect(Breakpoints.room({ width: 300, populate: null }), Infinity, "column");
    expect(Breakpoints.room({ width: 300, populate: null, flow: 0, columns: 2 }), Infinity, "grid");
    expect(Breakpoints.room({ width: 300, layoutDirection: 0 }), Infinity, "row layout");
    expect(Breakpoints.room({ width: 300, layoutDirection: 0, flow: 0, columns: 2 }), Infinity, "grid layout");
    """

    assert {"", 0} = Omunculus.GuiModules.run(["Breakpoints"], script)
  end
end
