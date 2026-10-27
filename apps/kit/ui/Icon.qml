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
    key: "M2 8a2.75 2.75 0 1 0 5.5 0a2.75 2.75 0 1 0 -5.5 0 M7.5 8h6.5 M11.5 8v2.5 M14 8v2"
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
      // 1.25 screen pixels at every size.
      strokeWidth: 1.25 * 16 / icon.size
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: icon.paths[icon.name] || "" }
    }
  }
}
