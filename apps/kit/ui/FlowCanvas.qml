import QtQuick

// FlowCanvas is a canvas without edges for a chart laid out in its own
// coordinates, `contentWidth` by `contentHeight`: its dots, a brighter cross
// every fifth, move with it; dragging moves it, a wheel zooms around the
// pointer, a touchpad's two fingers move it and zoom with Ctrl, two fingers
// pinch it. It frames the chart in the room its insets leave, whole unless
// that is smaller than `readable`, then from its top left, and frames it
// again when it changes size until it is moved by hand. Below its actual
// size the chart is drawn at that size and reduced through mipmaps, so its
// outlines, lines and text stay smooth.
Item {
  id: canvas

  property real contentWidth: 0
  property real contentHeight: 0
  // Room kept clear on each side when the chart is framed: what floats over
  // the canvas there.
  property real leftInset: 0
  property real topInset: 0
  property real rightInset: 0
  property real bottomInset: 0
  // The smallest scale framing goes to: below it the chart no longer reads.
  property real readable: 0.45
  // Whether it was moved or zoomed by hand since it was framed.
  property bool moved: false
  readonly property real zoomLevel: world.scale
  readonly property alias world: world
  default property alias content: world.data

  // A press on the canvas itself, not on what is drawn on it.
  signal backgroundClicked()
  // Framed: what was picked may be brought into view again.
  signal framed()

  function fit() {
    const room = Qt.size(width - leftInset - rightInset - 40, height - topInset - bottomInset - 40)
    if (contentWidth <= 0 || room.width <= 0 || room.height <= 0)
      return
    const scale = Math.max(readable, Math.min(1.2, room.width / contentWidth, room.height / contentHeight))
    world.scale = scale
    world.x = leftInset + 20 + Math.max(0, (room.width - contentWidth * scale) / 2)
    world.y = topInset + 20 + Math.max(0, (room.height - contentHeight * scale) / 2)
    moved = false
    framed()
  }
  onWidthChanged: if (!moved) Qt.callLater(fit)
  onHeightChanged: if (!moved) Qt.callLater(fit)

  // Brings the box {x, y, width, height}, in the chart's coordinates, into
  // the room the insets leave.
  function bringIntoView(box) {
    const right = width - rightInset - 20
    const x = world.x + box.x * world.scale
    const y = world.y + box.y * world.scale
    if (x + box.width * world.scale > right)
      world.x -= x + box.width * world.scale - right
    if (x < leftInset + 20)
      world.x += leftInset + 20 - x
    if (y < topInset + 20)
      world.y += topInset + 20 - y
    if (y + box.height * world.scale > height - bottomInset - 20)
      world.y -= y + box.height * world.scale - (height - bottomInset - 20)
  }

  // Zooms by `factor` keeping the point (px, py) of the view where it is.
  function zoom(factor, px, py) {
    const scale = Math.max(0.15, Math.min(2.5, world.scale * factor))
    const ratio = scale / world.scale
    world.x = px - (px - world.x) * ratio
    world.y = py - (py - world.y) * ratio
    world.scale = scale
    moved = true
  }
  function zoomIn() { zoom(1.2, width / 2, height / 2) }
  function zoomOut() { zoom(1 / 1.2, width / 2, height / 2) }
  function actualSize() { zoom(1 / world.scale, width / 2, height / 2) }

  Canvas {
    id: grid
    anchors.fill: parent
    onPaint: {
      const context = getContext("2d")
      context.reset()
      const step = 28 * world.scale
      if (step < 6)
        return
      const ox = ((world.x % step) + step) % step
      const oy = ((world.y % step) + step) % step
      const col = Math.round((world.x - ox) / step)
      const row = Math.round((world.y - oy) / step)
      // Far out, only the crosses stay.
      const dots = step >= 12
      for (let i = 0, x = ox; x < width; x += step, i++)
        for (let j = 0, y = oy; y < height; y += step, j++) {
          const major = (i - col) % 5 === 0 && (j - row) % 5 === 0
          if (!major && !dots)
            continue
          context.fillStyle = String(major ? Qt.alpha(Theme.primary, 0.22) : Qt.alpha(Theme.foreground, 0.09))
          if (major) {
            context.fillRect(x - 3, y, 7, 1)
            context.fillRect(x, y - 3, 1, 7)
          } else {
            context.fillRect(x, y, 1, 1)
          }
        }
    }
    Connections {
      target: world
      function onXChanged() { grid.requestPaint() }
      function onYChanged() { grid.requestPaint() }
      function onScaleChanged() { grid.requestPaint() }
    }
    Connections {
      target: Theme
      function onPrimaryChanged() { grid.requestPaint() }
    }
  }

  MouseArea {
    anchors.fill: parent
    property point last
    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
    onPressed: mouse => last = Qt.point(mouse.x, mouse.y)
    onPositionChanged: mouse => {
      world.x += mouse.x - last.x
      world.y += mouse.y - last.y
      canvas.moved = true
      last = Qt.point(mouse.x, mouse.y)
    }
    onClicked: canvas.backgroundClicked()
    onWheel: wheel => {
      if (wheel.pixelDelta.x === 0 && wheel.pixelDelta.y === 0 || wheel.modifiers & Qt.ControlModifier) {
        canvas.zoom(Math.pow(1.0015, wheel.angleDelta.y), wheel.x, wheel.y)
      } else {
        world.x += wheel.pixelDelta.x
        world.y += wheel.pixelDelta.y
        canvas.moved = true
      }
    }
  }

  PinchHandler {
    target: null
    property real last: 1
    onActiveChanged: last = 1
    onActiveScaleChanged: {
      canvas.zoom(activeScale / last, centroid.position.x, centroid.position.y)
      last = activeScale
    }
  }

  Item {
    id: world
    transformOrigin: Item.TopLeft
    width: canvas.contentWidth
    height: canvas.contentHeight
    layer.enabled: scale < 1
    layer.smooth: true
    layer.mipmap: true
  }
}
