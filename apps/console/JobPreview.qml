import QtQuick
import QtQuick.Layouts
import "kit/client/Jobs.js" as Jobs
import "kit/ui"

// JobPreview says what a schedule would do, as the server computes it: the
// schedule in words, its next three fires and the estimated cost of a fire
// with what the estimate is drawn from, or that there is no history to draw it
// from, under the lines of what the job sends when a card gives them. `fields` is a job's schedule, timezone and agent, workflow or tool (as
// Jobs.previewOf reads them); it asks again, a moment after the last change.
// A schedule the server refuses shows its sentence under the lines.
ColumnLayout {
  id: preview

  property var fields: ({})
  // What the job sends and where its replies go, as Jobs.lines gives them, to
  // show above the schedule; none in the form, which has them as its fields.
  property var lines: []
  // The colour of the words that say what is not the preview's own.
  property color dim: Theme.dim

  readonly property var request: Jobs.previewOf(fields)
  readonly property string asked: JSON.stringify(request)
  property var result: null
  property string failure: ""
  // Now, for the days the fires are given by.
  readonly property real now: Date.now()
  property int sent: 0

  spacing: Theme.space.tight

  onAskedChanged: {
    result = null
    failure = ""
    sent += 1
    if (request !== null)
      pause.restart()
    else
      pause.stop()
  }
  Component.onCompleted: if (request !== null) pause.restart()

  Timer {
    id: pause
    interval: 350
    onTriggered: {
      const turn = preview.sent
      Omunculus.jobs.preview(preview.request, data => {
        if (turn === preview.sent)
          preview.result = data
      }, reason => {
        if (turn === preview.sent)
          preview.failure = reason
      })
    }
  }

  component Line: RowLayout {
    id: line
    property string name
    property string text
    property color tone: Theme.foreground
    Layout.fillWidth: true
    visible: text !== ""
    spacing: Theme.space.gap
    Caption { Layout.preferredWidth: 100; Layout.alignment: Qt.AlignTop; text: line.name }
    Label {
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      text: line.text
      color: line.tone
      font.pixelSize: Theme.type.body.size
      wrapMode: Text.Wrap
    }
  }

  Repeater {
    model: preview.lines
    delegate: Line {
      required property var modelData
      name: modelData.name
      text: modelData.value
    }
  }
  Line {
    name: "RUNS"
    text: Jobs.when(preview.fields.schedule) + (preview.fields.timezone ? "  ·  " + preview.fields.timezone : "")
  }
  Line {
    name: "NEXT FIRES"
    text: Jobs.nextFires(preview.result, preview.now).join("\n")
  }
  Line {
    name: "ESTIMATE"
    text: Jobs.estimate(preview.result)
    tone: preview.dim
  }
  Label {
    Layout.fillWidth: true
    visible: preview.request !== null && preview.result === null && preview.failure === ""
    text: "working out the next fires…"
    color: preview.dim
    font.pixelSize: Theme.type.meta.size
  }
  FieldError { Layout.fillWidth: true; text: preview.failure }
}
