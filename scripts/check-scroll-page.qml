import QtQuick
import QtQuick.Layouts
import Quickshell
import "kit/ui"

// A page scrolled by hand, its content above the focused field then growing,
// as a preview arriving does: the page must stay where it was put.
// Prints "RESULT <scrolled to> <after the growth>".
ShellRoot {
  FloatingWindow {
    id: win
    implicitWidth: 390
    implicitHeight: 400
    color: Theme.background

    ScrollPage {
      id: page
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      ColumnLayout {
        id: column
        width: page.width
        Field { id: name; Layout.fillWidth: true; label: "name" }
        Rectangle { id: preview; Layout.fillWidth: true; Layout.preferredHeight: 300; color: "gray" }
        Rectangle { id: below; Layout.fillWidth: true; Layout.preferredHeight: 300; color: "darkgray" }
      }
    }

    property real scrolled: -1
    Timer { interval: 400; running: true; onTriggered: name.input.forceActiveFocus() }
    Timer { interval: 900; running: true; onTriggered: { page.scrollTo(150); win.scrolled = page.contentY } }
    Timer { interval: 1300; running: true; onTriggered: preview.Layout.preferredHeight = 420 }
    Timer { interval: 2000; running: true; onTriggered: { console.log("RESULT", Math.round(win.scrolled), Math.round(page.contentY), page.focused !== null); Qt.quit() } }
  }
}
