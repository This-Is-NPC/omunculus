// Frontend de exemplo: consome eventos JSON do harness, não o TTY.
//
//   qs -p examples/chat.qml
//
// Sobe:
//   omunculus monkey-job --json-events --tools counter --delay 30s --increment 1 "conte até 10"

import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root

  readonly property string here: {
    var url = String(Qt.resolvedUrl("."))
    return url.replace(/^file:\/\//, "").replace(/\/$/, "")
  }
  readonly property string repoDir: {
    var h = root.here
    if (h.slice(-9) === "/examples")
      return h.slice(0, h.length - 9)
    return h
  }

  property string bin: root.repoDir + "/omunculus"
  property string configFile: root.repoDir + "/presets/local.toml"
  property string model: "qwen3.5:4b"
  property string instruction: "conte até 10"
  property string delay: "30s"
  readonly property string jobPrompt: "Use the counter tool. Call it once per increment until the value is 10. Do not count in prose. Do not ask for confirmation. After 10, stop."

  property bool busy: runProc.running
  property string modelName: ""
  property int maxRounds: 0
  property int roundCount: 0
  property int toolCount: 0
  property int tokenCount: 0
  property double startedAt: 0
  property int elapsedMs: 0
  property string runOutcome: ""
  property string assistantText: ""

  readonly property color bg: "#101315"
  readonly property color bgRaised: "#181c1f"
  readonly property color bgInput: "#1c2124"
  readonly property color fg: "#cacccc"
  readonly property color muted: "#707880"
  readonly property color accent: "#8fa8a3"
  readonly property color userBg: "#24302e"
  readonly property color urgent: "#a55555"
  readonly property color ok: "#7d9a6a"

  function fmtMs(ms) {
    var n = Math.max(0, Number(ms) || 0)
    if (n < 1000)
      return Math.round(n) + "ms"
    return (n / 1000).toFixed(1) + "s"
  }

  function fmtClock(ms) {
    var n = Math.max(0, Math.floor((Number(ms) || 0) / 1000))
    var m = Math.floor(n / 60)
    var s = n % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  property var pendingArgv: []
  property string lastLine: ""
  property int lastExit: 0
  property int eventsSeen: 0

  function monkeyArgv(text) {
    return [
      root.bin,
      "monkey-job",
      "--json-events",
      "--config", root.configFile,
      "--model", root.model,
      "--tools", "counter",
      "--delay", root.delay,
      "--increment", "1",
      "--max-turns", "24",
      text
    ]
  }

  function resetRun() {
    timeline.clear()
    root.modelName = ""
    root.maxRounds = 0
    root.roundCount = 0
    root.toolCount = 0
    root.tokenCount = 0
    root.runOutcome = ""
    root.assistantText = ""
    root.elapsedMs = 0
    root.eventsSeen = 0
    root.lastLine = ""
  }

  function startJob(text) {
    var prompt = String(text || "").replace(/^\s+|\s+$/g, "")
    if (!prompt)
      prompt = root.instruction

    resetRun()
    root.startedAt = Date.now()
    root.pendingArgv = monkeyArgv(root.jobPrompt)
    timeline.append(item("user", { title: prompt, status: "ok" }))
    timeline.append(item("run", {
      title: root.model,
      detail: "local FLM · " + root.bin,
      status: "pending"
    }))

    if (runProc.running) {
      runProc.running = false
      kickTimer.restart()
      return
    }
    armProcess()
  }

  function armProcess() {
    runProc.workingDirectory = root.repoDir
    runProc.command = root.pendingArgv
    runProc.running = true
    root.lastLine = "starting " + root.bin
  }

  function item(kind, extra) {
    var row = {
      kind: kind,
      round: 0,
      title: "",
      detail: "",
      status: "pending",
      durationMs: 0,
      delayMs: 0,
      delayUntil: 0,
      tokens: 0,
      toolName: "",
      from: "",
      to: ""
    }
    for (var key in extra)
      row[key] = extra[key]
    return row
  }

  function tokensOf(event) {
    var usage = event && event.usage
    if (!usage)
      return 0
    return Number(usage.total_tokens || usage.totalTokens || 0)
  }

  function lastIndex(kind, round) {
    if (round === null || round === undefined)
      round = -1
    for (var i = timeline.count - 1; i >= 0; i--) {
      var row = timeline.get(i)
      if (row.kind === kind && (round < 0 || row.round === round))
        return i
    }
    return -1
  }

  function patch(index, fields) {
    if (index < 0)
      return
    for (var key in fields)
      timeline.setProperty(index, key, fields[key])
  }

  function ingest(raw) {
    var line = String(raw || "").replace(/^\s+|\s+$/g, "")
    if (!line)
      return
    root.lastLine = line
    if (line.charAt(0) !== "{") {
      timeline.append(item("run", {
        title: "stderr",
        detail: line,
        status: "fail"
      }))
      return
    }
    var event
    try {
      event = JSON.parse(line)
    } catch (e) {
      timeline.append(item("run", { title: "json", detail: line, status: "fail" }))
      return
    }

    root.eventsSeen += 1
    var type = event.type
    if (type === "run_started") {
      root.modelName = event.model || ""
      root.maxRounds = Number(event.max_rounds || 0)
      timeline.append(item("run", {
        title: root.modelName,
        detail: "max " + root.maxRounds + " rounds · counter · delay " + root.delay,
        status: "pending"
      }))
      return
    }

    if (type === "round_started") {
      root.roundCount = Math.max(root.roundCount, Number(event.round || 0))
      timeline.append(item("round", {
        round: Number(event.round || 0),
        title: "Round " + event.round,
        detail: "aguardando o modelo",
        status: "pending"
      }))
      return
    }

    if (type === "round_completed") {
      var outcome = event.outcome || ""
      var detail = outcome === "tool_calls"
        ? (event.tool_calls === 1 ? "1 tool call" : event.tool_calls + " tool calls")
        : (outcome === "final_response" ? "resposta final" : outcome)
      patch(lastIndex("round", Number(event.round)), {
        detail: detail,
        status: outcome === "final_response" ? "ok" : "ok",
        durationMs: Number(event.duration_ms || 0),
        tokens: tokensOf(event)
      })
      root.tokenCount += tokensOf(event)
      return
    }

    if (type === "round_failed") {
      patch(lastIndex("round", Number(event.round)), {
        detail: String(event.reason || "falhou"),
        status: "fail",
        durationMs: Number(event.duration_ms || 0)
      })
      return
    }

    if (type === "tool_started") {
      root.toolCount += 1
      var title = event.name || "tool"
      var detail = event.detail || ""
      if (event.name === "counter" && event.from != null)
        detail = event.from + " → " + event.to
      timeline.append(item("tool", {
        round: Number(event.round || 0),
        title: title,
        detail: detail,
        status: "pending",
        toolName: event.name || "",
        from: event.from == null ? "" : String(event.from),
        to: event.to == null ? "" : String(event.to)
      }))
      return
    }

    if (type === "tool_result_waiting") {
      var waitAt = lastIndex("tool", Number(event.round))
      var delayMs = Number(event.delay_ms || 0)
      patch(waitAt, {
        status: "wait",
        delayMs: delayMs,
        delayUntil: Date.now() + delayMs,
        detail: timeline.get(waitAt).detail
      })
      return
    }

    if (type === "tool_completed") {
      var ok = event.outcome === "completed" || event.outcome === "ok"
      patch(lastIndex("tool", Number(event.round)), {
        status: ok ? "ok" : "fail",
        durationMs: Number(event.duration_ms || 0),
        delayUntil: 0
      })
      return
    }

    if (type === "run_completed" || type === "run_failed") {
      root.runOutcome = type === "run_completed" ? (event.outcome || "completed") : "failed"
      root.toolCount = Number(event.tool_calls || root.toolCount)
      root.roundCount = Number(event.rounds || root.roundCount)
      root.elapsedMs = Number(event.duration_ms || root.elapsedMs)
      patch(lastIndex("run"), {
        status: type === "run_completed" ? "ok" : "fail",
        durationMs: Number(event.duration_ms || 0),
        detail: root.roundCount + " rounds · " + root.toolCount + " tools · " + root.tokenCount + " tokens"
      })
    }
  }

  function finish(exitCode) {
    root.lastExit = exitCode
    var out = String(runStdout.text || "").replace(/^\s+|\s+$/g, "")
    if (out) {
      root.assistantText = out
      timeline.append(item("assistant", { title: out, status: exitCode === 0 ? "ok" : "fail" }))
    } else if (exitCode !== 0) {
      timeline.append(item("run", {
        title: "exit " + exitCode,
        detail: root.eventsSeen === 0
          ? "o processo saiu sem emitir eventos — bin=" + root.bin
          : root.lastLine || ("exit " + exitCode),
        status: "fail"
      }))
    }
    patch(lastIndex("run", -1), {
      status: exitCode === 0 ? "ok" : "fail"
    })
    list.positionViewAtEnd()
  }

  ListModel {
    id: timeline
  }

  Timer {
    id: kickTimer
    interval: 20
    repeat: false
    onTriggered: root.armProcess()
  }

  Timer {
    interval: 200
    running: root.busy
    repeat: true
    onTriggered: {
      root.elapsedMs = Date.now() - root.startedAt
      for (var i = 0; i < timeline.count; i++) {
        var row = timeline.get(i)
        if (row.status === "wait" && row.delayUntil > 0)
          timeline.setProperty(i, "delayMs", Math.max(0, row.delayUntil - Date.now()))
      }
    }
  }

  Process {
    id: runProc
    running: false
    stdout: StdioCollector {
      id: runStdout
      waitForEnd: true
    }
    stderr: SplitParser {
      onRead: function (data) { root.ingest(data) }
    }
    onExited: function (exitCode) { root.finish(exitCode) }
  }

  FloatingWindow {
    title: "omunculus"
    color: root.bg
    implicitWidth: 560
    implicitHeight: 740
    minimumSize: Qt.size(420, 520)
    visible: true

    Rectangle {
      anchors.fill: parent
      color: root.bg

      Rectangle {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 78
        color: root.bgRaised

        Column {
          anchors.fill: parent
          anchors.margins: 16
          spacing: 6

          Row {
            spacing: 12
            Text {
              text: "omunculus"
              color: root.fg
              font.pixelSize: 16
              font.bold: true
            }
            Text {
              text: root.busy ? root.fmtClock(root.elapsedMs) : (root.runOutcome || "CLI")
              color: root.busy ? root.accent : root.muted
              font.pixelSize: 13
              font.family: "monospace"
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            width: parent.width
            text: (root.modelName || "modelo")
              + "  ·  " + root.roundCount + " rounds"
              + "  ·  " + root.toolCount + " tools"
              + (root.tokenCount ? "  ·  " + root.tokenCount + " tokens" : "")
            color: root.muted
            font.pixelSize: 12
            font.family: "monospace"
            elide: Text.ElideRight
          }
        }
      }

      ListView {
        id: list
        anchors.top: header.bottom
        anchors.bottom: composer.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 14
        clip: true
        spacing: 8
        model: timeline
        onCountChanged: positionViewAtEnd()

        delegate: Item {
          required property string kind
          required property int round
          required property string title
          required property string detail
          required property string status
          required property int durationMs
          required property int delayMs
          required property string toolName

          width: list.width
          height: card.height

          readonly property bool indent: kind === "tool"
          readonly property color statusColor: {
            if (status === "fail") return root.urgent
            if (status === "wait") return root.urgent
            if (status === "ok") return root.ok
            return root.accent
          }

          Rectangle {
            id: card
            x: indent ? 22 : 0
            width: parent.width - x
            height: col.height + 18
            radius: 10
            color: kind === "user" ? root.userBg : root.bgRaised
            border.width: kind === "run" ? 1 : 0
            border.color: root.muted

            Rectangle {
              width: 3
              height: parent.height - 16
              radius: 2
              anchors.verticalCenter: parent.verticalCenter
              x: 8
              color: statusColor
              visible: kind === "round" || kind === "tool"
            }

            Column {
              id: col
              x: (kind === "round" || kind === "tool") ? 20 : 12
              y: 9
              width: parent.width - x - 12
              spacing: 4

              Row {
                width: parent.width
                spacing: 8

                Text {
                  text: {
                    if (kind === "user") return "você"
                    if (kind === "assistant") return "assistente"
                    if (kind === "run") return "run"
                    if (kind === "round") return "round"
                    if (kind === "tool") return "tool"
                    return kind
                  }
                  color: root.muted
                  font.pixelSize: 10
                  font.letterSpacing: 0.4
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  visible: kind !== "user" && kind !== "assistant"
                  text: title
                  color: root.fg
                  font.pixelSize: 13
                  font.bold: kind === "round"
                  elide: Text.ElideRight
                  width: Math.max(40, parent.width - 120)
                }

                Item { width: 1; height: 1 }

                Text {
                  visible: status === "wait"
                  text: "delay " + root.fmtClock(delayMs)
                  color: root.urgent
                  font.pixelSize: 11
                  font.family: "monospace"
                }

                Text {
                  visible: durationMs > 0 && status !== "wait"
                  text: root.fmtMs(durationMs)
                  color: statusColor
                  font.pixelSize: 11
                  font.family: "monospace"
                }
              }

              Text {
                width: parent.width
                visible: detail.length > 0 && kind !== "user" && kind !== "assistant"
                text: status === "wait" ? (detail + "  ·  aguardando " + root.fmtClock(delayMs)) : detail
                color: status === "fail" ? root.urgent : root.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
              }

              Text {
                width: parent.width
                visible: kind === "assistant" || kind === "user"
                text: title
                color: root.fg
                font.pixelSize: 13
                wrapMode: Text.Wrap
              }
            }
          }
        }
      }

      Rectangle {
        id: composer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 56
        color: root.bgRaised

        Rectangle {
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          width: 168
          height: 36
          radius: 8
          color: root.busy ? root.muted : root.accent

          Text {
            anchors.centerIn: parent
            text: root.busy ? "rodando…" : "conte até 10"
            color: root.bg
            font.pixelSize: 12
            font.bold: true
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.startJob(root.instruction)
          }
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: 16
          anchors.right: parent.right
          anchors.rightMargin: 188
          anchors.verticalCenter: parent.verticalCenter
          text: root.busy
            ? ("rodando · " + root.model)
            : (root.lastLine || (root.model + " @ 127.0.0.1:52625"))
          color: root.muted
          font.pixelSize: 11
          font.family: "monospace"
          elide: Text.ElideMiddle
        }
      }
    }
  }
}
