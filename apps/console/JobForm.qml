pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Jobs.js" as Jobs
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// JobForm makes a job, or changes one: its name, the conversation it goes to
// (a new one for each fire, or a fixed one), the agent or workflow it is sent
// to and the message, the schedule and its time zone, an optional condition
// tool that gates each fire, an optional end and where each reply is
// delivered. Beside it, or under it on a narrow page, JobPreview says what the
// schedule would do. CREATE, or SAVE when changing, is the one filled action;
// the server's refusal shows under it, in words, and the form stays.
FocusScope {
  id: form

  // The fields as Jobs.blank gives them, and whether a job is being changed:
  // its name and its conversation then stay.
  property var draft: Jobs.blank()
  property bool editing: false
  property bool sending: false
  property string failure: ""

  // The job was made or changed, by its name.
  signal done(string name)
  signal cancelled()

  readonly property bool wide: width >= 900
  readonly property string problem: Jobs.problem(draft, !editing)
  readonly property var targets: draft.kind === "agent" ? Omunculus.talkable.map(each => each.name)
    : Omunculus.setup ? Omunculus.setup.workflows.map(each => each.name) : []

  // Starts over from `fields`; `changing` for a job that exists.
  function reset(fields, changing) {
    draft = fields
    editing = changing
    failure = ""
    sending = false
    message.text = fields.message
  }

  function set(key, value) {
    const next = Object.assign({}, draft)
    next[key] = value
    draft = next
  }

  function focusEntry() {
    if (editing)
      message.focusBox()
    else
      name.input.forceActiveFocus()
  }

  function submit() {
    if (problem !== "" || sending)
      return
    sending = true
    failure = ""
    const fail = reason => {
      sending = false
      failure = reason
    }
    if (editing)
      Omunculus.jobs.act(draft.name, "edit", Jobs.body(draft, true), () => {
        sending = false
        form.done(draft.name)
      }, fail)
    else
      Omunculus.jobs.create(Jobs.body(draft, false), () => {
        sending = false
        form.done(draft.name)
      }, fail)
  }

  // What a conversation is called, cut to fit a button.
  function conversationText(id) {
    const known = Omunculus.summaries[id]
    const title = known && known.title ? known.title : "new conversation"
    return title.length > 28 ? title.slice(0, 27) + "\u2026" : title
  }

  ScrollPage {
    id: page
    anchors.fill: parent
    contentWidth: width
    contentHeight: outer.implicitHeight
    activeFocusOnTab: false

    ColumnLayout {
      id: outer
      width: page.width
      spacing: Theme.space.block

      GridLayout {
        id: grid
        Layout.fillWidth: true
        columns: form.wide ? 2 : 1
        columnSpacing: Theme.space.section
        rowSpacing: Theme.space.block

        ColumnLayout {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignTop
          Layout.preferredWidth: 1
          spacing: Theme.space.block

          Label {
            Layout.fillWidth: true
            text: form.editing ? "Change " + form.draft.name : "New job"
            font.pixelSize: Theme.type.input.size
            font.bold: true
            elide: Text.ElideRight
          }

          Field {
            id: name
            Layout.fillWidth: true
            label: "name"
            value: form.draft.name
            placeholder: "morning-news"
            enabled: !form.editing
            opacity: enabled ? 1 : 0.6
            onEdited: text => form.set("name", text)
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space.tight
            Caption { text: "CONVERSATION" }
            Flow {
              Layout.fillWidth: true
              spacing: Theme.space.tight
              Chip {
                text: "A NEW ONE EACH FIRE"
                checked: form.draft.mode === "new"
                enabled: !form.editing
                onClicked: form.set("mode", "new")
              }
              Chip {
                text: "A FIXED ONE"
                checked: form.draft.mode === "fixed"
                enabled: !form.editing
                onClicked: form.set("mode", "fixed")
              }
              Dropdown {
                visible: form.draft.mode === "fixed"
                enabled: !form.editing
                options: Omunculus.conversations.map(each => each.id)
                current: form.draft.conversation
                label: form.draft.conversation === "" ? "CHOOSE ONE…" : form.conversationText(form.draft.conversation).toUpperCase()
                describe: id => form.conversationText(id)
                onPicked: id => form.set("conversation", id)
              }
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space.tight
            Caption { text: "RUNS" }
            Flow {
              Layout.fillWidth: true
              spacing: Theme.space.tight
              Chip {
                text: "AN AGENT"
                checked: form.draft.kind === "agent"
                onClicked: {
                  form.set("kind", "agent")
                  form.set("target", "")
                }
              }
              Chip {
                text: "A WORKFLOW"
                checked: form.draft.kind === "workflow"
                onClicked: {
                  form.set("kind", "workflow")
                  form.set("target", "")
                }
              }
              Dropdown {
                options: form.targets
                current: form.draft.target
                label: form.draft.target === "" ? "CHOOSE…" : form.draft.target.toUpperCase()
                onPicked: option => form.set("target", option)
              }
            }
          }

          TextArea {
            id: message
            Layout.fillWidth: true
            label: "message"
            placeholderText: "what it sends each time"
            onTextChanged: form.set("message", text)
          }

          GridLayout {
            Layout.fillWidth: true
            columns: form.wide ? 2 : 1
            columnSpacing: Theme.space.gap
            rowSpacing: Theme.space.block
            Field {
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              label: "schedule"
              value: form.draft.schedule
              placeholder: "daily at 07:00, every 2h or 0 9 * * 1"
              onEdited: text => form.set("schedule", text)
            }
            Field {
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              label: "time zone"
              value: form.draft.timezone
              placeholder: "Europe/Paris"
              onEdited: text => form.set("timezone", text)
            }
          }

          Field {
            Layout.fillWidth: true
            label: "condition tool (optional)"
            value: form.draft.condition
            placeholder: "a tool that must pass before each fire"
            onEdited: text => form.set("condition", text)
          }

          Field {
            Layout.fillWidth: true
            label: "ends (optional)"
            value: form.draft.end
            placeholder: "2026-12-31 or 2026-12-31 18:00, your time"
            onEdited: text => form.set("end", text)
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space.tight
            Caption { text: "DELIVERY" }
            Flow {
              Layout.fillWidth: true
              spacing: Theme.space.tight
              Chip {
                text: "NONE"
                checked: form.draft.delivery === ""
                onClicked: form.set("delivery", "")
              }
              Chip {
                text: "OWNER'S INBOX"
                icon: "send"
                tip: "each reply arrives in the owner's mailbox as a message from the job"
                checked: form.draft.delivery === "owner_inbox"
                onClicked: form.set("delivery", "owner_inbox")
              }
            }
          }
        }

        // Beside the form, or under it on a narrow page: what the schedule would do.
        Panel {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignTop
          Layout.preferredWidth: 1
          title: "preview"
          JobPreview {
            id: preview
            width: parent.width
            fields: Jobs.formFields(form.draft)
          }
        }
      }

      FieldError { Layout.fillWidth: true; text: form.failure }
      Label {
        Layout.fillWidth: true
        visible: form.problem !== "" && form.failure === ""
        text: form.problem
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
        wrapMode: Text.Wrap
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Theme.space.gap
        Item { Layout.fillWidth: true }
        Chip { text: "CANCEL"; onClicked: form.cancelled() }
        TraceButton {
          role: "primary"
          dense: true
          filled: true
          icon: form.editing ? "check" : "plus"
          text: form.editing ? "SAVE" : "CREATE"
          sending: form.sending
          reason: form.problem
          onClicked: form.submit()
        }
      }
    }
  }
}
