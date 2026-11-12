import QtQuick

// AgentName is an agent as the hierarchy shows it everywhere: its dot and its
// name, tracked, both in the agent's own `tone` (Omunculus.toneOf). Without
// the dot (`dot: false`) it is the name alone, for a row whose mark column
// already holds the dot. It is as wide as its name, at most `limit`, the name
// eliding to fit; give `limit` the room its place has.
Row {
  id: agent

  property string name: ""
  property color tone: Theme.dim
  property bool dot: true
  property real size: Theme.type.log.size
  property real limit: Infinity

  spacing: Theme.space.tight
  Accessible.role: Accessible.StaticText
  Accessible.name: name

  Dot { visible: agent.dot; anchors.verticalCenter: parent.verticalCenter; tone: agent.tone }
  Label {
    width: Math.min(implicitWidth, agent.limit - (agent.dot ? agent.spacing + Theme.space.tight : 0))
    text: agent.name
    color: agent.tone
    font.pixelSize: agent.size
    font.letterSpacing: Theme.type.header.tracking
    elide: Text.ElideRight
  }
}
