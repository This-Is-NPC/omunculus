import QtQuick
import "Breakpoints.js" as Breakpoints

// Caption names a field: small, dim, tracked text above its input, elided at
// the width of what holds it.
Label {
  width: Math.min(implicitWidth, Breakpoints.room(parent))
  elide: Text.ElideRight
  color: Theme.dim
  font.pixelSize: 10
  font.letterSpacing: 2.5
}
