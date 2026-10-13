import QtQuick

// Portrait is an agent's picture, cropped to the square it fills, or, while it
// has none, its initial in its colour on a faint wash of it. With a frame, a
// hairline goes round it. The picture is the file the app fetched for it.
Item {
  id: portrait

  required property string agent
  // The picture's url, "" while it has none, and the agent's colour.
  property url source
  property color tone: Theme.dim
  property bool framed: false
  property real initialSize: Math.max(8, Math.round(height * 0.45))

  Rectangle {
    anchors.fill: parent
    color: Qt.alpha(portrait.tone, 0.08)
    border.color: portrait.framed ? Theme.line : "transparent"
  }
  Label {
    anchors.centerIn: parent
    visible: picture.status !== Image.Ready
    text: portrait.agent.charAt(0).toUpperCase()
    color: portrait.tone
    font.pixelSize: portrait.initialSize
  }
  Image {
    id: picture
    anchors { fill: parent; margins: portrait.framed ? 1 : 0 }
    source: portrait.source
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    smooth: true
    mipmap: true
  }
}
