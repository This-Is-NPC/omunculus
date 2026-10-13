import QtQuick

// FileChip is a file attached in a conversation, {name, bytes}: its name and
// size, on a chip that opens it when chosen.
Chip {
  id: chip

  required property var file

  icon: "import"
  text: file.name + "  ·  " + (file.bytes < 1024 ? file.bytes + " B"
    : file.bytes < 1048576 ? (file.bytes / 1024).toFixed(1) + " KB"
    : (file.bytes / 1048576).toFixed(1) + " MB")
  tip: "save to downloads and open"
}
