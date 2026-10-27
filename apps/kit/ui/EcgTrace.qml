import QtQuick
import QtQuick.Shapes

// EcgTrace draws a wave like a monitor trace: a sample every 32 ms frame,
// swinging up and down by a fixed pattern, written by a bright head on the
// right and fading out to the left. It enters already drawn, a full window of
// samples behind it.
//
// The trace is laid out once, in pieces of a few samples each, on a strip that
// slides left once per display frame by the time that passed. A new sample
// rebuilds only the newest piece; the others keep their geometry on the GPU,
// so it scrolls at the display's rate for little CPU.
Item {
  id: trace

  property color tone: Theme.primary
  // The colour behind the trace, which the left edge fades into.
  property color backdrop: Theme.background
  // One sample per frame, about five seconds kept.
  readonly property int frameMs: 32
  readonly property int capacity: 160
  // Samples per piece: the most a new sample makes the CPU lay out again.
  readonly property int pieceSamples: 16

  // The samples' times, evenly spaced, oldest first, and the index of the
  // first since the trace began.
  property var times: []
  property int firstIndex: 0
  // When the strip's left edge was drawn: positions on it never move.
  property double origin: 0
  property real shift: 0
  property real headY: height / 2
  // The samples drawn, as {index, x, y} on the strip, oldest first.
  property var raw: []
  // The pieces drawn, oldest first: {first, shape} — `first` is the index in
  // `raw` of the piece's first sample; a piece ends on the next one's first.
  property var pieces: []
  // When a frame was last drawn. Without frames — the window hidden, on
  // another workspace — samples are not laid out; the first frame back lays
  // the whole trace out again.
  property double drawnAt: 0
  property bool stale: false

  clip: true

  // How far sample `index` swings, from 0 to 1.
  function level(index) {
    return 0.12 + 0.62 * Math.abs(Math.sin(index * 0.29) * Math.cos(index * 0.11))
  }

  // A full window of samples, ending now.
  function seed() {
    const now = Date.now()
    const times = []
    for (let i = 0; i < capacity; i++)
      times.push(now - (capacity - 1 - i) * frameMs)
    firstIndex = 0
    trace.times = times
    rebuild()
  }

  // The next sample, one frame after the last unless that drifted too far
  // from the clock.
  function push() {
    const now = Date.now()
    const expected = times[times.length - 1] + frameMs
    times.push(Math.abs(expected - now) > 250 ? now : expected)
    if (times.length > capacity) {
      times.shift()
      firstIndex += 1
    }
    append()
  }

  function span() { return capacity * frameMs }
  function at(time) { return (time - origin) / span() * width }

  // The point of sample `i`, on the strip.
  function sample(i) {
    const index = firstIndex + i
    // Alternate up and down by the sample's own index, so it never flips sides.
    const sign = index % 2 === 0 ? 1 : -1
    const mid = height / 2
    return { index: index, x: at(times[i]), y: mid - sign * level(index) * mid * 0.7 }
  }

  // Lay the whole trace out again: a new size, or a gap in the frames.
  function rebuild() {
    for (const piece of pieces)
      piece.shape.destroy()
    pieces = []
    raw = []
    if (times.length === 0)
      return
    origin = times[0]
    for (let i = 0; i < times.length; i++)
      raw.push(sample(i))
    for (let first = 0; first < raw.length - 1; first += pieceSamples)
      pieces.push({ first: first, shape: pieceShape.createObject(strip) })
    for (let k = 0; k < pieces.length; k++)
      draw(k)
    slide()
  }

  // Take the newest sample: only the newest piece is laid out again.
  function append() {
    if (Date.now() - drawnAt > 250) {
      stale = true
      return
    }
    const last = times.length - 1
    if (pieces.length === 0 || firstIndex + last !== raw[raw.length - 1].index + 1)
      return rebuild()
    raw.push(sample(last))
    let newest = pieces.length - 1
    if (raw.length - 1 - pieces[newest].first > pieceSamples) {
      // The newest piece is full: it ends where the next begins, and its last
      // stretch now knows what follows it.
      pieces.push({ first: raw.length - 2, shape: pieceShape.createObject(strip) })
      draw(newest)
      newest += 1
    }
    draw(newest)
    forget()
  }

  // Drop the samples and pieces that left the strip on the left; after a long
  // while the strip starts over, so its positions stay precise.
  function forget() {
    if (at(Date.now()) > 50 * width)
      return rebuild()
    const gone = at(Date.now() - 2 * frameMs) - width - 4
    while (pieces.length > 1 && raw[pieces[1].first].x < gone) {
      pieces[0].shape.destroy()
      const dropped = pieces[1].first
      pieces.shift()
      raw.splice(0, dropped)
      for (const piece of pieces)
        piece.first -= dropped
    }
  }

  // Lay out piece `k` as a curve through its samples: Catmull-Rom, two extra
  // points per stretch, reading one sample on each side for the tangents.
  function draw(k) {
    const first = pieces[k].first
    const end = k + 1 < pieces.length ? pieces[k + 1].first : raw.length - 1
    const smooth = []
    for (let i = first; i < end; i++) {
      const p0 = raw[Math.max(i - 1, 0)], p1 = raw[i], p2 = raw[i + 1], p3 = raw[Math.min(i + 2, raw.length - 1)]
      for (const t of [0, 1 / 3, 2 / 3]) {
        const t2 = t * t, t3 = t2 * t
        smooth.push(Qt.point(
          0.5 * (2 * p1.x + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
          0.5 * (2 * p1.y + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)))
      }
    }
    smooth.push(Qt.point(raw[end].x, raw[end].y))
    pieces[k].shape.points = smooth
  }

  // Slide the strip by the time that passed, and keep the head on the trace.
  // The head runs two frames behind the newest sample, so the line reaches it.
  function slide() {
    if (raw.length < 2)
      return
    shift = width - 3 - at(Date.now() - 2 * frameMs)
    const edge = width - 3 - shift
    for (let i = raw.length - 1; i > 0; i--) {
      if (raw[i - 1].x <= edge) {
        const a = raw[i - 1], b = raw[i]
        const t = b.x === a.x ? 0 : Math.min(1, Math.max(0, (edge - a.x) / (b.x - a.x)))
        headY = a.y + (b.y - a.y) * t
        return
      }
    }
  }

  Component.onCompleted: seed()
  onWidthChanged: rebuild()
  onHeightChanged: rebuild()
  Component.onDestruction: {
    for (const piece of pieces)
      piece.shape.destroy()
  }

  Timer {
    interval: trace.frameMs
    repeat: true
    running: true
    onTriggered: trace.push()
  }

  FrameAnimation {
    running: trace.visible
    onTriggered: {
      trace.drawnAt = Date.now()
      if (trace.stale) {
        trace.stale = false
        trace.rebuild()
      }
      trace.slide()
    }
  }

  Item {
    id: strip
    anchors.fill: parent
    transform: Translate { x: trace.shift }
  }

  Component {
    id: pieceShape
    // Pieces meet end to end with flat caps: the curve's tangent runs on across
    // the joint, and no overlap draws a brighter dot there.
    Shape {
      property var points: []
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeWidth: 1.4
        strokeColor: trace.tone
        fillColor: "transparent"
        joinStyle: ShapePath.RoundJoin
        capStyle: ShapePath.FlatCap
        PathPolyline { path: points }
      }
    }
  }

  // The older end fades into what lies behind.
  Rectangle {
    width: parent.width * 0.45
    height: parent.height
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0; color: trace.backdrop }
      GradientStop { position: 1; color: Qt.alpha(trace.backdrop, 0) }
    }
  }

  // The writing head.
  Rectangle {
    x: trace.width - 3 - width / 2
    y: trace.headY - height / 2
    width: 12
    height: 12
    radius: 6
    color: Qt.alpha(trace.tone, 0.18)
    Rectangle {
      anchors.centerIn: parent
      width: 4.4
      height: 4.4
      radius: 2.2
      color: trace.tone
    }
  }
}
