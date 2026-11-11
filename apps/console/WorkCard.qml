pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Pending.js" as Pending
import "kit/ui"

// WorkCard is a work handed down, once, in the chat: its title, its state
// as an icon and a word, how long, who works for it now, who it waits for,
// and the stages of its workflow, with OPEN IN TREE to read it where it sits
// among the works. Narrow, the stages are a bar of one segment each and the
// button has its own line. Its runs and steps are not here; they are in the
// tree.
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

    Fact {
      visible: card.view !== null && card.view.now !== null
      name: "NOW"
      who: card.view && card.view.now ? card.view.now.agent : ""
      text: card.view && card.view.now ? card.view.now.doing : ""
    }
    Fact {
      visible: card.view !== null && card.view.waits !== ""
      name: "WAITS"
      text: card.view ? card.view.waits : ""
    }

    GridLayout {
      Layout.fillWidth: true
      columns: card.stacked ? 1 : 2
      columnSpacing: Theme.space.section
      rowSpacing: Theme.space.gap

      ColumnLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: Theme.space.tight
        visible: card.view !== null && card.view.stage !== null
        Label {
          visible: card.stacked && card.view !== null && card.view.stage !== null
          text: card.view && card.view.stage ? "STAGE " + card.view.stage.at + "/" + card.view.stage.count + (card.view.stage.name !== "" ? "  ·  " + card.view.stage.name.toUpperCase() : "") : ""
          color: Theme.dim
          font.pixelSize: Theme.type.header.size
          font.letterSpacing: Theme.type.meta.tracking
          elide: Text.ElideRight
          Layout.fillWidth: true
        }
        RowLayout {
          visible: card.stacked
          Layout.fillWidth: true
          spacing: Theme.space.tight
          Repeater {
            model: card.view && card.stacked ? card.view.steps : []
            delegate: Rectangle {
              required property var modelData
              Layout.fillWidth: true
              implicitHeight: Theme.space.tight
              color: ({ done: Theme.success, current: Theme.primary })[modelData.status] || Theme.line
            }
          }
        }
        Stepper {
          visible: !card.stacked
          Layout.fillWidth: true
          steps: card.view && !card.stacked ? card.view.steps : []
          round: card.view ? card.view.round : 0
          tip: card.view && card.view.stage ? "stage " + card.view.stage.at + " of " + card.view.stage.count : ""
        }
      }

      TraceButton {
        Layout.fillWidth: card.stacked
        Layout.alignment: card.stacked ? Qt.AlignLeft : Qt.AlignRight | Qt.AlignVCenter
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
