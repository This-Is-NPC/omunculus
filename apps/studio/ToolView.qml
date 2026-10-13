pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ToolView is one entry of the catalog, a tool or an MCP server: what it is
// for, where it comes from, its triggers and groups, the secrets it declares
// and the provider bound to each, and the agents that have it. The catalog is
// folders and the config's servers, which the studio only reads.
ItemPage {
  id: page

  required property Item settings
  // The catalog's entry: {name, kind, description, dir, source, triggers, groups, secrets, binding}.
  required property var entry

  related: [
    { title: "AGENTS", items: (entry.triggers || []).includes("model") ? Studio.holders(entry.name).map(agent => settings.link(2, agent)) : [] },
    { title: "PROVIDERS", items: [...new Set(Object.values(entry.binding || {}))].map(provider => settings.link(0, provider)) },
    { title: "SKILLS THAT USE IT", items: (settings.catalog ? settings.catalog.tools : [])
        .filter(skill => skill.kind === "skill" && (skill.uses || []).includes(entry.name)).map(skill => settings.link(5, skill.name, skill.name.slice(6))) }
  ]

  kind: entry.kind
  title: entry.name
  facts: [
    ["from", entry.source === "inline" ? "inline in the project's config" : entry.dir || ""],
    ["triggers", (entry.triggers || []).join(", ")],
    ["groups", (entry.groups || []).join(", ")],
    ["secrets", (entry.secrets || []).map(secret => secret + " ← " + ((entry.binding || {})[secret] || "unbound")).join(", ")],
    ["had by", (entry.triggers || []).includes("model") ? Studio.holders(entry.name).join(", ") : ""]
  ]
  details: [
    Label {
      Layout.fillWidth: true
      text: page.entry.description || ""
      color: Theme.foreground
      font.pixelSize: 12
      wrapMode: Text.Wrap
    }
  ]
}
