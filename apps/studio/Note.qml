import QtQuick
import QtQuick.Layouts
import "kit/ui"

// Note says, dimmed, what the fields beside it are for; it decodes as its
// section comes.
DecodeLabel {
  Layout.fillWidth: true
  color: Theme.dim
  font.pixelSize: 11
  wrapMode: Text.Wrap
}
