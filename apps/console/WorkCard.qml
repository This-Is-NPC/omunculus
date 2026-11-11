pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Pending.js" as Pending
import "kit/ui"

// WorkCard is a work handed down, once, in the chat: its title, its state
// as an icon and a word, how long, and who it waits for, with OPEN IN TREE to
// read it where it sits among the works. Where the work stands, its stages and
// who is at work, is the progress strip's alone, and the live line under the
// thread says what the agent at work does; its runs and steps are in the tree.
SurfaceFrame {
  id: card

  // The work, by id.
  required property string work
  property string stamp: ""
  // The work is wanted in the tree.
  signal opened(string work)

  readonly property var node: Omunculus.progress ? Omunculus.progress.flat.find(item => item.work === work) || null : null
  readonly property var view: node ? Pending.workCard(node, Omunculus.tick) : null
  readonly property bool stacked: width < Theme.size.measureFrom

  // A work not read yet has no card.
  implicitHeight: view ? content.implicitHeight + Theme.space.insetTop + Theme.space.insetTop : 0
  visible: view !== null
  variant: "outline"

  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: Theme.space.insetTop; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
    spacing: Theme.space.gap

    GridLayout {
      Layout.fillWidth: true
      columns: card.stacked ? 2 : 4
      columnSpacing: Theme.space.gap
      rowSpacing: Theme.space.tight
      RowLayout {
        Layout.fillWidth: card.stacked
        spacing: Theme.space.tight
        Icon { name: "map"; size: 12; color: Theme.primary }
        Label {
          text: "WORK"
          color: Theme.primary
          font.pixelSize: Theme.type.header.size
          font.letterSpacing: Theme.type.kicker.tracking
        }
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.columnSpan: card.stacked ? 2 : 1
        Layout.row: card.stacked ? 1 : 0
        Layout.column: card.stacked ? 0 : 1
        text: card.view ? card.view.title : ""
        color: Theme.foreground
        font.pixelSize: Theme.type.cardBody.size
        font.bold: true
        wrapMode: Text.Wrap
      }
      StateMark {
        Layout.row: card.stacked ? 2 : 0
        Layout.column: card.stacked ? 0 : 2
        Layout.columnSpan: card.stacked ? 2 : 1
        Layout.fillWidth: card.stacked
        state: card.view ? card.view.state : ""
        text: card.view ? card.view.word : ""
      }
      Label {
        Layout.row: 0
        Layout.column: card.stacked ? 1 : 3
        Layout.alignment: Qt.AlignRight
        text: card.view ? card.view.elapsed.toUpperCase() : ""
        color: Theme.dim
        font.pixelSize: Theme.type.header.size
        font.letterSpacing: Theme.type.kicker.tracking
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.gap
      Fact {
        visible: card.view !== null && card.view.waits !== ""
        name: "WAITS"
        text: card.view ? card.view.waits : ""
      }
      Item { visible: card.view === null || card.view.waits === ""; Layout.fillWidth: true }
      TraceButton {
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        dense: true
        role: "action"
        icon: "chevron-right"
        text: "OPEN IN TREE"
        tip: "read this work where it sits among the works"
        onClicked: card.opened(card.work)
      }
    }
  }

  // A line of the card: a caption, who it is of, in their tone, and words.
  component Fact: RowLayout {
    id: fact
    property string name
    property string who
    property string text
    Layout.fillWidth: true
    spacing: Theme.space.gap
    Caption { Layout.preferredWidth: 46; Layout.alignment: Qt.AlignTop; text: fact.name }
    Dot { visible: fact.who !== ""; Layout.alignment: Qt.AlignTop; Layout.topMargin: Theme.space.line; tone: Omunculus.toneOf(fact.who) }
    Label {
      visible: fact.who !== ""
      Layout.alignment: Qt.AlignTop
      text: fact.who
      color: Omunculus.toneOf(fact.who)
      font.pixelSize: Theme.type.body.size
      font.bold: true
    }
    Label {
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      text: fact.text
      color: Theme.dim
      font.pixelSize: Theme.type.body.size
      wrapMode: Text.Wrap
    }
  }
}
