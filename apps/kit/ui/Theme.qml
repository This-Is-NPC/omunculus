pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Colour.js" as Colour

Singleton {
  id: root

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
  readonly property string currentPath: stateHome + "/omarchy/current"
  readonly property string themePath: currentPath + "/theme"
  readonly property string colorsPath: themePath + "/colors.toml"
  readonly property var fallback: ({
    background: "#121212", foreground: "#e5e2e1", accent: "#39ff14",
    cyan: "#8fae9a", muted: "#494543", green: "#86d27a",
    yellow: "#ffb347", red: "#ff5544", magenta: "#c4a7e7"
  })
  // The hint on screen, so that only one shows at a time.
  property var shownHint: null
  property string mode: "dark"
  property var palette: ({})
  property color background: fallback.background
  property color foreground: fallback.foreground
  property color primary: fallback.accent
  property color secondary: fallback.cyan
  property color success: fallback.green
  property color warning: fallback.yellow
  property color error: fallback.red
  property color magenta: fallback.magenta
  readonly property color highlight: Qt.tint(background, Qt.alpha(foreground, mode === "light" ? 0.07 : 0.05))
  readonly property color line: Qt.alpha(foreground, 0.12)
  readonly property color dim: readable(palette.muted || foreground, background, foreground)
  // Dimmer than `dim`, for marks beside a text that names the same thing, as
  // a tab's digit: 3:1 on the background.
  readonly property color faint: readable(palette.muted || foreground, background, foreground, 3)
  readonly property color badgeForeground: background
  readonly property color placeholder: Qt.alpha(dim, 0.55)
  readonly property string fontFamily: "monospace"

  // The spacing every layout reads instead of a number of its own; the
  // `…Short` values are for a window under 560 px tall.
  readonly property QtObject space: QtObject {
    // The window's margin, the one margin everywhere.
    readonly property int page: 20
    readonly property int pageShort: 10
    // Between the masthead, a header strip, tabs and the content.
    readonly property int section: 18
    readonly property int sectionShort: 8
    // Between the blocks of a page: search, chips, list.
    readonly property int block: 14
    readonly property int blockShort: 8
    // Inside a framed block (strip, card, composer): across, and above.
    readonly property int inset: 14
    readonly property int insetTop: 12
    // Before a trailing button in a strip or a row.
    readonly property int trail: 6
    // Between controls on a line, and paragraphs in a card.
    readonly property int gap: 10
    // Between chips, and a card's sub-lines.
    readonly property int tight: 6
    // Between a heading and its bubble, and timeline entries.
    readonly property int line: 4
    // Between list rows, and a row's cell padding.
    readonly property int row: 2
    readonly property int cell: 12
  }

  readonly property QtObject size: QtObject {
    // A header strip.
    readonly property int strip: 40
    // A list row, and a stacked one: its top and each line.
    readonly property int row: 52
    readonly property int stackedRow: 22
    readonly property int stackedLine: 20
    // A section rule (Kicker).
    readonly property int rule: 26
    readonly property int control: 44
    readonly property int controlDense: 28
    readonly property int chip: 26
    // Room beside a bubble for its tools, and the bubble's own inset.
    readonly property int gutter: 24
    readonly property int bubbleInset: 10
    // A bubble's measure: this share of the width from `measureFrom` px,
    // under it the width less the gutter.
    readonly property real measure: 0.78
    readonly property int measureFrom: 520
    // The column a thread's system row (a step, a sub-work, a live line)
    // keeps for its icon; its words start after it.
    readonly property int mark: 18
  }

  // Each text role: its pixel size and letter spacing, and what else it needs.
  readonly property QtObject type: QtObject {
    // The agent's name over a bubble, and the time beside it, dimmed.
    readonly property QtObject name: QtObject { readonly property int size: 10; readonly property real tracking: 2.5 }
    readonly property QtObject stamp: QtObject { readonly property int size: 9; readonly property real tracking: 1; readonly property real opacity: 0.7 }
    // A bubble, and a card's body.
    readonly property QtObject body: QtObject { readonly property int size: 12; readonly property real lineHeight: 1.2 }
    readonly property QtObject cardBody: QtObject { readonly property int size: 13; readonly property real lineHeight: 1.2 }
    // A thread's system rows: steps, sub-works, the live line; the log, not messages.
    readonly property QtObject log: QtObject { readonly property int size: 11 }
    // A card's kind, in the accent.
    readonly property QtObject kicker: QtObject { readonly property int size: 10; readonly property real tracking: 3 }
    // A strip's meta, uppercase, its parts joined by `separator`.
    readonly property QtObject meta: QtObject { readonly property int size: 10; readonly property real tracking: 2; readonly property string separator: "  ·  " }
    // A table header and a row's status.
    readonly property QtObject header: QtObject { readonly property int size: 9; readonly property real tracking: 1 }
    readonly property QtObject section: QtObject { readonly property int size: 10; readonly property real tracking: 3 }
    // A tab: its digit, then its name.
    readonly property QtObject tabDigit: QtObject { readonly property int size: 10; readonly property real tracking: 2 }
    readonly property QtObject tab: QtObject { readonly property int size: 11; readonly property real tracking: 3 }
    // The composer's line, with its padding, and its chevron.
    readonly property QtObject input: QtObject { readonly property int size: 13; readonly property int padding: 10; readonly property int chevron: 14; readonly property int chevronTop: 12 }
  }
  // The desktop asks for no animation: read once at start; motion stays on
  // when the setting cannot be read.
  property bool reducedMotion: false

  // Up to eight colours for agents, as "#rrggbb": the theme's own made
  // readable, then their hues turned when it has fewer. Each is a turn of
  // `hueGap` from every other, and none is near the accent, the colours of
  // success, warning and failure, or the text's own ink, so no agent reads as
  // a state or as body text.
  readonly property var agentPalette: distinct([
    secondary, magenta, palette.orange, palette.blue, palette.bright_cyan,
    palette.bright_magenta, palette.bright_blue
  ], 8)
  // Colours at least this far apart in RGB (0 to √3) read as different from
  // the accent, the states and the text; agents differ by `hueGap` of a turn
  // in hue (1 is 360°) from each other, the accent and the states.
  readonly property real apart: 0.15
  readonly property real hueGap: 1 / 12

  // An agent's colour, by its place among `agents` ([{name}]); dim when it is
  // not there.
  function agentTone(agents, name) {
    const at = agents.findIndex(agent => agent.name === name)
    return at < 0 ? dim : agentPalette[at % agentPalette.length]
  }

  function distinct(wanted, count) {
    const hexOf = color => String(color)
    return Colour.palette(wanted.filter(color => color).map(hexOf), count, hexOf(background), hexOf(foreground),
      [primary, success, warning, error].map(hexOf), apart, hueGap)
  }

  Process {
    running: true
    command: ["gsettings", "get", "org.gnome.desktop.interface", "enable-animations"]
    stdout: StdioCollector { onStreamFinished: root.reducedMotion = text.trim() === "false" }
  }

  FileView {
    id: colorsFile
    path: root.colorsPath
    watchChanges: true
    printErrors: false
    onFileChanged: root.scheduleReload()
    onLoaded: root.apply(text())
  }

  FileView {
    id: themeDirectory
    path: root.themePath
    watchChanges: true
    printErrors: false
    onFileChanged: root.scheduleReload()
  }

  FileView {
    path: root.currentPath
    watchChanges: true
    printErrors: false
    onFileChanged: root.scheduleReload()
  }

  Timer {
    id: reloadTimer
    interval: 100
    onTriggered: {
      colorsFile.path = ""
      themeDirectory.path = ""
      Qt.callLater(function() {
        themeDirectory.path = root.themePath
        colorsFile.path = root.colorsPath
        colorsFile.reload()
      })
    }
  }

  function scheduleReload() {
    reloadTimer.restart()
  }

  function rgb(value) {
    const match = String(value).match(/^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/)
    return match ? [1, 2, 3].map(i => parseInt(match[i], 16) / 255) : null
  }

  // `wanted` moved toward `ink` until it reads on `base`, at `ratio` or
  // 4.5:1 (Colour.js).
  function readable(wanted, base, ink, ratio) {
    return Colour.readable(String(wanted), String(base), String(ink), ratio)
  }

  // A speech bubble's fill: the speaker's tone over the background, or, for
  // the person's own words (no tone), the text's ink.
  function bubble(tone) {
    return Qt.tint(background, Qt.alpha(tone === undefined ? foreground : tone, tone === undefined ? 0.09 : 0.14))
  }

  // The dim tone, adjusted to read on `fill`, a surface over the background.
  function readableOn(fill) {
    return readable(palette.muted || foreground, Qt.tint(background, fill), foreground)
  }

  function apply(toml) {
    const colors = {}
    let themeMode = "dark"
    for (const line of toml.split("\n")) {
      const match = line.match(/^\s*(\w+)\s*=\s*"([^"]+)"/)
      if (match && match[1] === "mode")
        themeMode = match[2]
      else if (match && /^#[0-9a-fA-F]{6}$/.test(match[2]))
        colors[match[1]] = match[2]
    }
    mode = themeMode === "light" ? "light" : "dark"
    palette = colors
    background = colors.background || fallback.background
    foreground = colors.foreground || fallback.foreground
    primary = readable(colors.accent || fallback.accent, background, foreground)
    secondary = readable(colors.cyan || fallback.cyan, background, foreground)
    success = readable(colors.green || fallback.green, background, foreground)
    warning = readable(colors.yellow || fallback.yellow, background, foreground)
    error = readable(colors.red || fallback.red, background, foreground)
    magenta = readable(colors.magenta || fallback.magenta, background, foreground)
  }
}
