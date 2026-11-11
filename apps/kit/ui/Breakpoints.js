.pragma library

// The widths the apps change their layout at, the only place they live. The
// chrome (masthead, rail, bar, dock) asks with the window's width; a card, a
// form or a row asks with its own.
const narrowBelow = 700, wideFrom = 1100, tightBelow = 420;

function size(width) { return width >= wideFrom ? "wide" : width >= narrowBelow ? "medium" : "narrow"; }
function tight(width) { return width < tightBelow; }
function margin(width) { return width < tightBelow ? 8 : width < narrowBelow ? 10 : width < wideFrom ? 16 : 20; }
// The height of a dense control: taller where it is touched rather than
// pointed at, the 44 px of `Theme.size.control`.
function target(width) { return width < narrowBelow ? 44 : 28; }
function indent(width) { return width < narrowBelow ? 12 : 16; }

// The most a control may be wide inside `parent`: the parent's width, unless
// the parent is a Row, Column or Grid, which takes its width from the
// control, or a layout, which sizes the control itself, or has no width yet.
function room(parent) {
  if (!parent)
    return Infinity;
  const positioner = "populate" in parent && (!("flow" in parent) || "columns" in parent);
  const layout = "layoutDirection" in parent && !("populate" in parent);
  return positioner || layout || !(parent.width > 0) ? Infinity : parent.width;
}
