import QtQuick
import "Words.js" as Words

// DecodeLabel reveals a label's changed text from left to right, using the
// selected glyph set until each character resolves. Spacing and punctuation are
// never scrambled, so the text keeps its shape. Labels and short state text
// only: text a reader follows as it grows is drawn as it is. With reduced
// motion the text appears at once. Assistive technology reads the value, never
// the glyphs in between. With `byWords`, a text that does not fit is cut at a
// word, not mid-word.
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
  property bool byWords: false
  // What is drawn once the text has settled: the value, cut at a word when it does not fit.
  readonly property string settled: byWords && width > 0 ? Words.atWord(value, fit.elidedText) : value

  TextMetrics {
    id: fit
    font: label.font
    elide: Text.ElideRight
    elideWidth: Math.max(0, label.width - label.leftPadding - label.rightPadding)
    text: label.byWords ? label.value : ""
  }

  text: settled
  Accessible.name: value
  onSettledChanged: {
    if (ready && autoPlay)
      replay()
    else
      text = settled
  }
  Component.onCompleted: {
    ready = true
    if (autoPlay)
      replay()
  }

  // Decode the whole value again, as when it comes into view. A decode under
  // way takes a new value on its next frame: text arriving faster than frames
  // never lays the label out more than once a frame.
  function replay() {
    if (Theme.reducedMotion) {
      scramble.stop()
      text = settled
      return
    }
    if (!settled.length) {
      scramble.stop()
      text = ""
      return
    }
    elapsed = 0
    if (scramble.running)
      return
    updateText()
    scramble.start()
  }

  function updateText() {
    const resolved = Math.floor(settled.length * Math.min(1, elapsed / Math.max(1, duration)))
    let output = settled.slice(0, resolved)
    for (let i = resolved; i < settled.length; i++) {
      const character = settled[i]
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
      if (label.elapsed >= label.duration) {
        stop()
        label.text = label.settled
      }
    }
  }
}
