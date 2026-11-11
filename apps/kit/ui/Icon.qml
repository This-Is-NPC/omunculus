import QtQuick
import QtQuick.Shapes

// Icon is the apps' one icon set: thin line drawings on a 16-unit grid, one
// stroke weight, round ends, so every glyph matches the hairline UI instead of
// borrowing whatever a fallback font draws.
Item {
  id: icon

  property string name
  property color color: Theme.foreground
  property real size: 14
  // Stroke weight in screen pixels, the same at every size.
  property real weight: 1.25

  // Drawn in a layer: a curve-rendered shape escapes the clip of a list that
  // holds it, and an icon of an entry scrolled out of view showed above it.
  layer.enabled: true

  readonly property var paths: ({
    play: "M5 3.5v9l7.5-4.5z",
    list: "M3 4.5h10 M3 8h10 M3 11.5h10",
    search: "M7 2.5a4.5 4.5 0 1 0 0 9a4.5 4.5 0 1 0 0-9z M10.3 10.3l3.2 3.2",
    board: "M2.5 3h3v10h-3z M6.5 3h3v6h-3z M10.5 3h3v8h-3z",
    import: "M8 2.5v8 M4.5 7l3.5 3.5 3.5-3.5 M3 13.5h10",
    edit: "M3 4h6 M3 7h5 M3 10h6 M12 3.5v9 M10.5 3.5h3 M10.5 12.5h3",
    close: "M4.5 4.5l7 7 M11.5 4.5l-7 7",
    trash: "M2.5 4.5h11 M6 4.5v-2h4v2 M4 4.5l0.7 9h6.6l0.7-9 M6.8 7v4 M9.2 7v4",
    copy: "M6 6h7v7h-7z M3.5 10.5v-7h7",
    "chevron-down": "M4.5 6.5l3.5 3.5 3.5-3.5",
    "chevron-up": "M4.5 9.5l3.5-3.5 3.5 3.5",
    "chevron-left": "M9.5 4.5l-3.5 3.5 3.5 3.5",
    open: "M9.5 2.5h4v4 M13.5 2.5l-6 6 M11.5 9v4.5h-9v-9h4.5",
    "chevron-right": "M6.5 4.5l3.5 3.5-3.5 3.5",
    enter: "M12.5 3.5v4.5c0 1-0.5 1.5-1.5 1.5h-7.5 M6 7l-2.5 2.5 2.5 2.5",
    warning: "M8 2.5l6 11h-12z M8 6.5v3.5 M8 12v0.01",
    spark: "M8 3l1.4 3.6 3.6 1.4-3.6 1.4-1.4 3.6-1.4-3.6-3.6-1.4 3.6-1.4z",
    people: "M4 5a2 2 0 1 0 4 0a2 2 0 1 0 -4 0 M2.5 13v-0.5a3.5 3.5 0 0 1 7 0v0.5 M10.5 3.2a2 2 0 0 1 0 3.6 M11.5 9.3a3.5 3.5 0 0 1 2 3.2v0.5",
    plus: "M8 3.5v9 M3.5 8h9",
    folder: "M2.5 4.5v8h11v-6.5h-6l-1.5-1.5z",
    more: "M3.5 8h0.01 M8 8h0.01 M12.5 8h0.01",
    check: "M3.5 8.5l3 3 6-7",
    send: "M13.5 2.5l-11 4.5 4.5 2 2 4.5z M7 9l6.5-6.5",
    map: "M2.5 3.5h4v3h-4z M9.5 9.5h4v3h-4z M9.5 3.5h4v3h-4z M6.5 5h3 M4.5 6.5v3.5c0 .6.4 1 1 1h4",
    cost: "M8 2v12 M11 4.5c0-1-1.3-1.5-3-1.5s-3 .7-3 2c0 3 6 1.5 6 4.5 0 1.3-1.3 2-3 2s-3-.6-3-1.7",
    attach: "M11 4.5v7a3 3 0 0 1 -6 0v-8a2 2 0 0 1 4 0v7",
    key: "M2 8a2.75 2.75 0 1 0 5.5 0a2.75 2.75 0 1 0 -5.5 0 M7.5 8h6.5 M11.5 8v2.5 M14 8v2",
    info: "M2.5 8a5.5 5.5 0 1 0 11 0a5.5 5.5 0 1 0 -11 0 M8 7.5v3.5 M8 5.2v0.01",
    // A prompt and its line: a step an agent took.
    step: "M3 4.5l3.5 3.5-3.5 3.5 M8.5 11.5h4.5",
    // A line that branches off: a work handed down.
    branch: "M4.5 2.5v11 M4.5 5.5c0 3 2 4 5 4h3 M10.5 7.5l2 2-2 2",
    // Two quote marks: words quoted from someone.
    quote: "M3 8h3.5v3.5h-3.5z M3 8c0-2.2 1-3.5 3-4 M9.5 8h3.5v3.5h-3.5z M9.5 8c0-2.2 1-3.5 3-4",
    // A question in a circle: a question for you.
    help: "M2.5 8a5.5 5.5 0 1 0 11 0a5.5 5.5 0 1 0 -11 0 M6.3 6.6a1.7 1.7 0 0 1 3.4 0c0 1.1-1.7 1.4-1.7 2.5 M8 11.2v0.01",
    // A diamond with a way through: a choice between options.
    diamond: "M8 2l6 6-6 6-6-6z M5.5 8h5 M8.5 6l2 2-2 2",
    // A shield with a tick: a capability granted.
    shield: "M8 2l5 2v3.5c0 3-2 5-5 6.5-3-1.5-5-3.5-5-6.5v-3.5z M5.8 8l1.7 1.7 2.8-3.4"
  })

  implicitWidth: size
  implicitHeight: size

  Shape {
    width: 16
    height: 16
    preferredRendererType: Shape.CurveRenderer
    transform: Scale { xScale: icon.size / 16; yScale: icon.size / 16 }

    ShapePath {
      strokeColor: icon.color
      // The dots of "more" are strokes of no length: a heavier one fills them.
      strokeWidth: (icon.name === "more" ? 2 : 1) * icon.weight * 16 / icon.size
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: icon.paths[icon.name] || "" }
    }
  }
}
