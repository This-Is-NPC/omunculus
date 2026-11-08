pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// RequestDialog is one request's decision, opened from a page: its card, to
// choose an option, answer in words or, escalating, raise it with the words
// as the reason; the card's menu switches between the two. It closes when the
// request no longer waits, so a send that fails leaves the card open with the
// words kept.
ModalDialog {
  id: dialog

  maxWidth: 560
  // The request shown, and whether its words escalate it.
  property string key: ""

  function show(request, escalate) {
    key = request
    card.escalating = escalate
    open()
  }

  onOpened: card.focusWords()

  contentItem: DialogPanel {
    dialogOpen: dialog.visible
    index: card.escalating ? "E" : "R"
    title: card.escalating ? "escalate" : "reply"
    active: true

    ColumnLayout {
      id: form
      anchors.fill: parent
      spacing: Theme.space.section

      ScrollPage {
        id: scroll
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(card.implicitHeight, dialog.parent ? dialog.parent.height - 200 : card.implicitHeight)
        contentHeight: card.implicitHeight

        RequestDecision {
          id: card
          width: scroll.width
          key: dialog.key
          onOpenChanged: if (!open && dialog.visible) dialog.close()
        }
      }

      DialogFooter {
        cancelText: "CLOSE"
        onCancelled: dialog.close()
      }
    }
  }
}
