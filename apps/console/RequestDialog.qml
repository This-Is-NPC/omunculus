pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// RequestDialog is one request's decision, opened from the bar of a page: its
// card, to choose an option, answer in words or, escalating, raise it with the
// words as the reason. It closes when the request no longer waits, so a send
// that fails leaves the card open with the words kept.
ModalDialog {
  id: dialog

  maxWidth: 560
  // The request shown, and whether its words escalate it.
  property string key: ""
  property bool escalating: false

  function show(request, escalate) {
    key = request
    escalating = escalate
    open()
  }

  onOpened: escalating ? card.focusWords() : card.focusDecision()

  contentItem: DialogPanel {
    dialogOpen: dialog.visible
    implicitHeight: form.implicitHeight + 56
    index: dialog.escalating ? "E" : "R"
    title: dialog.escalating ? "escalate" : "reply"
    active: true

    ColumnLayout {
      id: form
      anchors.fill: parent
      spacing: 18

      ScrollPage {
        id: scroll
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(card.implicitHeight, dialog.parent ? dialog.parent.height - 200 : card.implicitHeight)
        contentHeight: card.implicitHeight

        RequestDecision {
          id: card
          width: scroll.width
          key: dialog.key
          escalating: dialog.escalating
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
