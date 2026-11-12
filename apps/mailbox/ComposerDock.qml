pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Composers.js" as Composers
import "kit/ui"
import "kit/ui/Breakpoints.js" as Breakpoints

// ComposerDock is where the composers of Mail.composers sit, over the
// mailbox and never in its layout: windows docked at the bottom right, the
// newest on the right and the older ones shifting left, the minimized and the
// crowded out as tabs of their bar; one expanded in the middle over a dim
// backdrop. On a phone every composer is a tab of one strip, docked at the
// bottom of the mailbox, and the active one fills the screen under the strip,
// its minimize returning to the mailbox. A composer lives from its opening
// to its closing, whatever it shows, so what it holds stays.
Item {
  id: dock

  // Whether a composer holds the keyboard, which Esc then minimizes instead of closing the thread.
  property int holding: 0
  readonly property bool focused: holding > 0
  // How high the docked windows and tabs reach, for what floats over them.
  readonly property real occupied: phone ? (tabs.active === "" && items.length > 0 ? strip : 0) : docked.reduce((most, slot) => Math.max(most, slot.height), 0)

  readonly property bool phone: Breakpoints.size(width) === "narrow"
  readonly property var items: Mail.composers.items
  readonly property var slots: Composers.layout(Mail.composers, width, Theme.space.page)
  readonly property var tabs: Composers.phone(Mail.composers)
  readonly property bool expanded: items.some(item => item.mode === "full")
  readonly property real windowHeight: Math.min(500, Math.round(height * 0.7))
  readonly property real strip: Breakpoints.target(width)
  // The slots as heights, for `occupied`.
  readonly property var docked: slots.map(slot => ({ height: slot.shape === "window" ? windowHeight : Theme.size.strip }))

  function of(id) { return items.find(item => item.id === id) || null }

  ListModel { id: ids }
  // The model of ids only grows and shrinks, so a composer is never rebuilt.
  function sync() {
    const now = items.map(item => item.id)
    for (let at = ids.count - 1; at >= 0; at--)
      if (!now.includes(ids.get(at).cid))
        ids.remove(at)
    for (const id of now)
      if (!Array.from({ length: ids.count }, (_, at) => ids.get(at).cid).includes(id))
        ids.append({ cid: id })
  }
  onItemsChanged: sync()
  Component.onCompleted: sync()

  // The dim backdrop of the expanded one; a press on it docks it again.
  Rectangle {
    anchors.fill: parent
    visible: dock.expanded && !dock.phone
    color: Qt.alpha(Theme.background, 0.75)
    MouseArea {
      anchors.fill: parent
      onClicked: {
        const full = dock.items.find(item => item.mode === "full")
        if (full)
          Mail.expandComposer(full.id)
      }
    }
  }

  Repeater {
    model: ids
    delegate: ComposerWindow {
      id: window
      required property string cid
      readonly property var record: dock.of(cid)
      readonly property var slot: dock.slots.find(each => each.id === cid) || null
      readonly property int place: dock.tabs.tabs.indexOf(cid)
      readonly property bool active: dock.tabs.active === cid
      readonly property real across: dock.tabs.tabs.length === 0 ? 0
        : (dock.width - (dock.tabs.active !== "" ? dock.strip : 0)) / dock.tabs.tabs.length

      entry: record || ({ id: cid, kind: "new", draft: "", subject: "", body: "", to: [], thread: "", replied: "", request: "", quoted: null, mode: "open" })
      z: shape === "full" ? 2 : 1
      onActiveFocusChanged: dock.holding += activeFocus ? 1 : -1

      shape: !record ? "hidden"
        : dock.phone ? (active ? "screen" : "tab")
        : record.mode === "full" ? "full"
        : slot ? slot.shape : "hidden"
      barX: place * across
      barWidth: across
      x: dock.phone ? (active ? 0 : barX) : shape === "full" ? Math.round((dock.width - width) / 2) : slot ? slot.x : 0
      width: dock.phone ? (active ? dock.width : across) : shape === "full" ? Math.min(dock.width - 2 * Theme.space.page, 760) : slot ? slot.width : 0
      height: shape === "tab" ? (dock.phone ? dock.strip : Theme.size.strip)
        : shape === "window" ? dock.windowHeight
        : shape === "full" ? Math.min(dock.height - 2 * Theme.space.page, 640)
        : dock.height
      y: dock.phone ? (active ? 0 : dock.tabs.active !== "" ? 0 : dock.height - height)
        : shape === "full" ? Math.round((dock.height - height) / 2) : dock.height - height
    }
  }
}
