import QtQuick
import QtQuick.Layouts
import "kit/ui"

// OptionalNumber is a whole number of an item's draft that may be unset:
// left empty, the key leaves the item.
Field {
  id: optional

  required property ItemDraft draft
  required property var path
  readonly property var number: draft ? optional.path.reduce((at, key) => at && at[key], draft.draft) : undefined

  Layout.fillWidth: false
  value: number === undefined || number === null ? "" : String(number)
  placeholder: "unset"
  input.validator: RegularExpressionValidator { regularExpression: /[0-9]{0,9}/ }
  input.inputMethodHints: Qt.ImhDigitsOnly
  onEdited: text => draft.put(optional.path, text === "" ? null : Number(text))
}
