import QtQuick
import QtQuick.Layouts
import "kit/ui"

// Divider parts two columns with a hairline that fades out downwards, as the
// masthead's rule fades out to the right.
Rectangle {
  Layout.fillHeight: true
  implicitWidth: 1
  gradient: Gradient {
    GradientStop { position: 0; color: Theme.line }
    GradientStop { position: 1; color: "transparent" }
  }
}
