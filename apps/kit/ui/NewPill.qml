import QtQuick

// NewPill points to content that arrived out of view, below it or, `above`,
// above it: a lit chip on an opaque backing that counts it, as NEW or as
// the `word` it is given. It slides in from
// that side when it has something to point to and fades when it has not.
Item {
  id: pill

  // How many entries arrived out of view; none hides the pill.
  property int count: 0
  // Whether the content it points to is above it, and the key that jumps there.
  property bool above: false
  property string shortcut: above ? "" : "End"
  // What it counts, and what a click does, in words.
  property string word: "NEW"
  property string tip: "Jump to the newest entries" + (shortcut !== "" ? " (" + shortcut + ")" : "")
  readonly property bool shown: count > 0
  // The count shown, kept while the pill fades.
  property int shownCount: 0
  onCountChanged: if (count > 0) shownCount = count
  signal clicked()

  implicitWidth: chip.implicitWidth
  implicitHeight: chip.implicitHeight
  visible: opacity > 0
  opacity: shown ? 1 : 0
  transform: Translate { y: pill.shown ? 0 : pill.above ? -8 : 8; Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } } }
  Behavior on opacity { NumberAnimation { duration: pill.shown ? 180 : 120; easing.type: Easing.OutCubic } }

  Rectangle {
    anchors.fill: parent
    color: Theme.background
  }

  Chip {
    id: chip
    anchors.fill: parent
    checked: true
    icon: pill.above ? "chevron-up" : "chevron-down"
    text: pill.shownCount + " " + pill.word
    tip: pill.tip
    onClicked: pill.clicked()
  }
}
