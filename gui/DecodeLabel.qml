import QtQuick

// DecodeLabel reveals changed text from left to right, using the selected
// glyph set until each character resolves. While `appending`, a value that
// extends the previous one decodes only what it adds, so streamed text grows
// without scrambling what was already read, catching up a quarter of what is
// left each frame however fast the text comes. Spacing, punctuation and
// Markdown marks are never scrambled, so formatted text keeps its shape.
Label {
  id: label

  property string value
  property bool soft: false
  property bool revealOnStage: true
  readonly property string symbolGlyphs: "▓▒░<>/\\|_-=+*#01"
  readonly property string kanaGlyphs: "アイウエオカキクケコサシスセソタチツテトナニヌネノ"
  readonly property string glyphs: soft ? kanaGlyphs : symbolGlyphs
  property int duration: soft ? 420 : 320
  property bool autoPlay: !soft
  property int elapsed: 0
  property bool ready: false
  property bool appending: false
  // Characters left as they are by the current decode, and those resolved so far.
  property int settled: 0
  property int resolved: 0
  property string previous: ""

  text: value
  onValueChanged: {
    const grows = appending && value.startsWith(previous)
    settled = grows ? Math.min(resolved, previous.length) : 0
    if (!grows)
      resolved = 0
    previous = value
    if (ready && autoPlay) {
      decode()
    } else {
      text = value
      resolved = value.length
    }
  }
  Component.onCompleted: {
    ready = true
    if (autoPlay)
      replay()
  }

  // Decode the whole value again, as when it comes into view.
  function replay() {
    settled = 0
    resolved = 0
    decode()
  }

  // A decode under way takes a new value on its next frame: text arriving faster
  // than frames never lays the label out more than once a frame.
  function decode() {
    if (!value.length) {
      scramble.stop()
      text = ""
      resolved = 0
      return
    }
    elapsed = 0
    if (scramble.running)
      return
    updateText()
    scramble.start()
  }

  // Done once every character has resolved: by time, or, appending, by catching up.
  readonly property bool done: appending ? resolved >= value.length : elapsed >= duration

  function updateText() {
    if (appending) {
      resolved = Math.min(value.length, Math.max(settled, resolved + Math.max(4, Math.ceil((value.length - resolved) / 4))))
    } else {
      const fraction = Math.min(1, elapsed / Math.max(1, duration))
      resolved = settled + Math.floor((value.length - settled) * fraction)
    }
    let output = value.slice(0, resolved)
    for (let i = resolved; i < value.length; i++) {
      const character = value[i]
      output += /[\s.,!?·:*_#`>\-\[\]()|]/.test(character) ? character : glyphs[Math.floor(Math.random() * glyphs.length)]
    }
    text = output
  }

  Timer {
    id: scramble
    interval: 32
    repeat: true
    onTriggered: {
      label.elapsed += interval
      label.updateText()
      if (label.done) {
        stop()
        label.text = label.value
        label.resolved = label.value.length
      }
    }
  }
}
