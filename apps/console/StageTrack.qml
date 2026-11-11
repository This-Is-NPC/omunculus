import QtQuick
import "kit/client/Progress.js" as Progress
import "kit/ui"

// StageTrack is a work's stages as dots joined by hairlines — done filled in
// the success tone, the current one in the accent with a ring, those to come
// hollow — and under them where it is: "3/4 write". Nothing for a work in no
// workflow.
Item {
  id: track

  // A Progress node.
  property var node: null
  readonly property var where: node ? Progress.track(node) : null
  readonly property real dot: 8
  readonly property real link: 6

  visible: where !== null
  implicitWidth: Math.max(strip.width, label.implicitWidth)
  implicitHeight: visible ? strip.height + Theme.space.line + label.implicitHeight : 0
  Accessible.role: Accessible.StaticText
  Accessible.name: where ? "step " + where.step + " of " + where.steps + ", " + where.stage : ""

  Row {
    id: strip
    height: track.dot
    spacing: 0
    Repeater {
      model: track.node ? track.node.steps : []
      delegate: Row {
        id: cell
        required property var modelData
        required property int index
        spacing: 0
        Rectangle {
          visible: cell.index > 0
          anchors.verticalCenter: parent.verticalCenter
          width: track.link
          height: 1
          color: cell.modelData.status === "next" ? Theme.faint : Theme.success
        }
        Item {
          width: track.dot
          height: track.dot
          Rectangle {
            anchors.centerIn: parent
            width: track.dot - (cell.modelData.status === "current" ? 2 : 0)
            height: width
            radius: width / 2
            color: cell.modelData.status === "done" ? Theme.success : cell.modelData.status === "current" ? Theme.primary : "transparent"
            border.color: cell.modelData.status === "done" ? Theme.success : cell.modelData.status === "current" ? Theme.primary : Theme.dim
          }
          Rectangle {
            visible: cell.modelData.status === "current"
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.color: Theme.primary
          }
        }
      }
    }
  }
  Label {
    id: label
    anchors { top: strip.bottom; topMargin: Theme.space.line }
    width: track.width
    text: track.where ? track.where.step + "/" + track.where.steps + " " + track.where.stage : ""
    color: Theme.dim
    font.pixelSize: Theme.type.meta.size
    elide: Text.ElideRight
  }
}
