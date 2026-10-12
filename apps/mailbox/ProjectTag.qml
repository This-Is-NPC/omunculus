import QtQuick
import "kit/ui"

// ProjectTag names the project a thread is in, as a tracked caption.
Label {
  property string name
  text: name.toUpperCase()
  color: Theme.dim
  font.pixelSize: 9
  font.letterSpacing: 2
}
