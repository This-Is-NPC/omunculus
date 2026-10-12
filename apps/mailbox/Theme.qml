pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
  id: root

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
  readonly property string currentPath: stateHome + "/omarchy/current"
  readonly property string themePath: currentPath + "/theme"
  readonly property string colorsPath: themePath + "/colors.toml"
  readonly property var fallback: ({
    background: "#121212", foreground: "#e5e2e1", accent: "#39ff14",
    green: "#86d27a", yellow: "#ffb347", red: "#ff5544"
  })
  property string mode: "dark"
  property var palette: ({})
  property color background: fallback.background
  property color foreground: fallback.foreground
  property color primary: fallback.accent
  property color success: fallback.green
  property color warning: fallback.yellow
  property color error: fallback.red
  readonly property color highlight: Qt.tint(background, Qt.alpha(foreground, mode === "light" ? 0.07 : 0.05))
  readonly property color line: Qt.alpha(foreground, 0.12)
  readonly property color dim: readable(palette.muted || foreground, background, foreground)
  readonly property color badgeForeground: background
  readonly property string fontFamily: "monospace"

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

  function luminance(color) {
    const channel = value => value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4)
    return 0.2126 * channel(color[0]) + 0.7152 * channel(color[1]) + 0.0722 * channel(color[2])
  }

  function contrast(a, b) {
    const first = luminance(a)
    const second = luminance(b)
    return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05)
  }

  function readable(wanted, base, ink) {
    const color = rgb(wanted)
    const backgroundColor = rgb(base)
    const foregroundColor = rgb(ink)
    if (!color || !backgroundColor || !foregroundColor)
      return ink
    for (let step = 0; step <= 20; step++) {
      const amount = step / 20
      const mixed = color.map((channel, index) => channel + (foregroundColor[index] - channel) * amount)
      if (contrast(mixed, backgroundColor) >= 4.5)
        return Qt.rgba(mixed[0], mixed[1], mixed[2], 1)
    }
    return ink
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
    success = readable(colors.green || fallback.green, background, foreground)
    warning = readable(colors.yellow || fallback.yellow, background, foreground)
    error = readable(colors.red || fallback.red, background, foreground)
  }
}
