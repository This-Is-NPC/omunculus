pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic as C
import "kit/ui"

// ThreadList is the threads of the folder, grouped by day under kickers. It
// keeps a model of its own, of the threads' keys, in step with `Mail.shown`, so a thread that
// arrives fades and rises in, one that leaves fades out, and the others slide
// to their places; a thread that arrives while the list is on screen decodes
// its subject. Empty, it says why, and offers to clear the search.
Item {
  id: list

  signal chosen()

  // Puts the keyboard on the threads: the one on screen, or the first.
  function enter() {
    view.forceActiveFocus()
    if (view.currentIndex < 0 && model.count > 0)
      view.currentIndex = 0
  }

  // Whether the model was filled once; what comes after is fresh.
  property bool filled: false

  ListModel { id: model }

  // Brings the model in step with the threads shown, by key.
  function sync() {
    const wanted = Mail.shown
    const keys = wanted.map(thread => thread.key)
    for (let i = model.count - 1; i >= 0; i--)
      if (!keys.includes(model.get(i).key))
        model.remove(i)
    wanted.forEach((thread, index) => {
      let at = -1
      for (let i = 0; i < model.count; i++)
        if (model.get(i).key === thread.key) { at = i; break }
      const day = Mail.day(thread.at)
      if (at < 0)
        model.insert(index, { key: thread.key, day: day, fresh: list.filled })
      else {
        if (at !== index)
          model.move(at, index, 1)
        if (model.get(index).day !== day)
          model.setProperty(index, "day", day)
      }
    })
    filled = filled || Mail.primed
  }

  Connections {
    target: Mail
    function onShownChanged() { list.sync() }
  }
  Component.onCompleted: sync()

  ListView {
    id: view
    anchors.fill: parent
    clip: true
    model: model
    spacing: 2
    boundsBehavior: Flickable.StopAtBounds
    keyNavigationEnabled: true
    currentIndex: -1
    highlightFollowsCurrentItem: false
    C.ScrollBar.vertical: C.ScrollBar {}

    section.property: "day"
    section.delegate: Kicker {
      required property string section
      width: view.width
      text: section
    }

    delegate: ThreadRow {
      required property string key
      required property bool fresh
      required property int index
      thread: Mail.threads[key] || Mail.blank
      width: view.width
      onChosen: { view.currentIndex = index; Mail.open(thread.key); list.chosen() }
    }

    Keys.onReturnPressed: if (currentIndex >= 0) { Mail.open(model.get(currentIndex).key); list.chosen() }
    onCurrentIndexChanged: if (activeFocus && currentIndex >= 0) Mail.open(model.get(currentIndex).key)

    // Only once the list was filled: the first threads are simply there. A
    // displacement settles the opacity too, so an arrival it interrupts ends
    // fully shown.
    add: Transition {
      enabled: list.filled
      ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 260 }
        NumberAnimation { property: "y"; from: ViewTransition.destination.y + 16; duration: 300; easing.type: Easing.OutCubic }
      }
    }
    remove: Transition {
      enabled: list.filled
      NumberAnimation { property: "opacity"; to: 0; duration: 140 }
    }
    displaced: Transition {
      enabled: list.filled
      NumberAnimation { property: "y"; duration: 180; easing.type: Easing.OutCubic }
      NumberAnimation { property: "opacity"; to: 1; duration: 140 }
    }
    move: Transition {
      enabled: list.filled
      NumberAnimation { property: "y"; duration: 180; easing.type: Easing.OutCubic }
      NumberAnimation { property: "opacity"; to: 1; duration: 140 }
    }
  }

  // Why the list is empty.
  Column {
    anchors.centerIn: parent
    width: parent.width - 32
    spacing: 12
    visible: model.count === 0
    LoadingTrace {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: Mail.sweeping && !Mail.primed
      width: 96
      height: 16
      running: visible
    }
    Label {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: !Mail.connected ? "THE SERVER DOES NOT ANSWER"
        : !Mail.primed ? "READING YOUR MAIL"
        : Mail.query !== "" ? "NO THREAD MATCHES “" + Mail.query.toUpperCase() + "”"
        : "NO MAIL HERE"
      color: Theme.dim
      font.pixelSize: 11
      font.letterSpacing: 2
    }
    TraceButton {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: Mail.query !== "" || Mail.project !== ""
      dense: true
      role: "progress"
      icon: "close"
      text: "CLEAR FILTERS"
      onClicked: { Mail.query = ""; Mail.project = ""; list.cleared() }
    }
  }

  signal cleared()
}
