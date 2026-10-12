import QtQuick
import QtQuick.Shapes

// Icon is the mailbox's one icon set: thin line drawings on a 16-unit grid, one
// stroke weight, round ends, so every glyph matches the hairline UI instead of
// borrowing whatever a fallback font draws.
Item {
  id: icon

  property string name
  property color color: Theme.foreground
  property real size: 14
  // Stroke weight in screen pixels, the same at every size.
  property real weight: 1.25

  readonly property var paths: ({
    plus: "M8 3.5v9 M3.5 8h9",
    send: "M13.5 2.5l-11 4.5 4.5 2 2 4.5z M7 9l6.5-6.5",
    inbox: "M2.5 8.5l2-5.5h7l2 5.5v4.5h-11z M2.5 8.5h3.5l0.8 1.8h2.4l0.8-1.8h3.5",
    warning: "M8 2.5l6 11h-12z M8 6.5v3.5 M8 12v0.01"
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
      strokeWidth: icon.weight * 16 / icon.size
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: icon.paths[icon.name] || "" }
    }
  }
}
