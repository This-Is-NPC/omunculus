pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ProviderView is one provider of [auth]: what kind of login it is and where
// its key comes from — a variable of the server, a command, omapass, a stored
// login or the file itself — and the models that name it. The key is never
// shown.
ItemPage {
  id: page

  required property Item settings
  required property string name

  readonly property var table: item.draft
  readonly property bool literal: settings.literalKeys.includes(name) && table.key === undefined
  readonly property var omapass: Studio.omapass
  readonly property string key: table.key === undefined ? "" : String(table.key)
  readonly property var omapassKey: /^!(.*omapass'?) get -- (.+)$/.exec(key)
  readonly property string source: literal ? "file"
    : table.key === undefined || key === "" ? "login"
    : key.startsWith("$") ? "variable"
    : omapassKey ? "omapass"
    : key.startsWith("!") ? "command"
    : "file"
  readonly property var users: settings.keysOf("models").filter(model => settings.document.models[model].provider === name)

  function quoted(text) { return /^[A-Za-z0-9_.\/@:+=-]+$/.test(text) ? text : "'" + text.replace(/'/g, "'\\''") + "'" }
  function unquoted(text) { return /^'.*'$/.test(text) ? text.slice(1, -1).replace(/'\\''/g, "'") : text }
  function fromOmapass(account) { return "!" + quoted(omapass.program) + " get -- " + quoted(account) }

  kind: "provider"
  draft: ItemDraft {
    id: item
    section: "auth"
    name: page.name
    stored: page.settings.stored("auth", page.name)
    fresh: ({ kind: "api_key", key: "" })
    taken: page.settings.listed.auth
  }
  facts: [
    ["kind", table.kind || ""],
    ["key from", table.kind !== "api_key" ? "" : ({ file: "the file", login: "a stored login", variable: "the variable " + key.slice(1), omapass: "omapass", command: "a command" })[source]],
    ["models", users.join(", ")]
  ]

  PickRow {
    text: "KIND"
    options: ["api_key", "oauth-code", "tool"]
    current: page.table.kind || ""
    onPicked: kind => item.put(["kind"], kind)
  }
  Caption { visible: page.table.kind === "api_key"; text: "KEY FROM" }
  Flow {
    Layout.fillWidth: true
    visible: page.table.kind === "api_key"
    spacing: 6
    Chip {
      text: "VARIABLE"
      checked: page.source === "variable"
      onClicked: item.put(["key"], "$" + page.name.toUpperCase().replace(/[^A-Z0-9]/g, "_") + "_API_KEY")
    }
    Chip {
      text: "COMMAND"
      checked: page.source === "command"
      onClicked: item.put(["key"], "!")
    }
    Chip {
      visible: page.source === "omapass" || (page.omapass !== null && page.omapass.installed)
      text: "OMAPASS"
      checked: page.source === "omapass"
      onClicked: if (page.omapass && page.omapass.installed) item.put(["key"], page.fromOmapass((page.omapass.accounts[0] || { account: "" }).account))
    }
    Chip {
      text: "STORED LOGIN"
      checked: page.source === "login"
      onClicked: item.put(["key"], "")
    }
    Chip {
      visible: page.settings.literalKeys.includes(page.name)
      text: "IN THE FILE"
      checked: page.source === "file"
      onClicked: item.put(["key"], null)
    }
  }
  Field {
    visible: page.table.kind === "api_key" && page.source === "variable"
    Layout.fillWidth: true
    label: "environment variable of the server"
    value: page.key.slice(1)
    onEdited: text => item.put(["key"], "$" + text.trim())
  }
  Field {
    visible: page.table.kind === "api_key" && page.source === "command"
    Layout.fillWidth: true
    label: "command that prints the key"
    value: page.key.slice(1)
    onEdited: text => item.put(["key"], "!" + text)
  }
  PickRow {
    visible: page.table.kind === "api_key" && page.source === "omapass" && page.omapass !== null && page.omapass.installed
    text: "PASSWORD"
    options: page.omapass && page.omapass.accounts ? page.omapass.accounts.map(entry => entry.account) : []
    current: page.omapassKey ? page.unquoted(page.omapassKey[2]) : ""
    describe: account => {
      const entry = ((page.omapass || {}).accounts || []).find(each => each.account === account)
      return entry && entry.folder ? entry.folder + " / " + account : account
    }
    onPicked: account => item.put(["key"], page.fromOmapass(account))
  }
  FieldError {
    Layout.fillWidth: true
    visible: page.table.kind === "api_key" && page.source === "omapass"
    text: page.omapass === null ? "" : !page.omapass.installed ? "omapass is not installed; this key cannot be read" : page.omapass.error || ""
  }
  Note {
    visible: page.table.kind === "api_key" && page.source === "login"
    value: "The key a login stored for " + page.name + "; `omunculus login --provider " + page.name + "` stores it."
  }
  Note {
    visible: page.table.kind === "api_key" && page.source === "file"
    value: "The key is written in the project's config as it is; it stays there, unread here."
  }
  // The other kinds keep their own fields as text.
  Repeater {
    model: page.table.kind === "api_key" ? [] : Object.keys(page.table).filter(field => field !== "kind" && typeof page.table[field] === "string")
    delegate: Field {
      required property string modelData
      Layout.fillWidth: true
      label: modelData.replace(/_/g, " ")
      value: page.table[modelData]
      onEdited: text => item.put([modelData], text)
    }
  }
}
