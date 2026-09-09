defmodule Omunculus.Events do
  @moduledoc """
  The event catalog (docs/to-be/event-catalog.md): every envelope type the
  harness accepts, declared once. The Event Core validates each append
  against it; `omunculus events catalog` renders it; the config check uses it
  to validate `[[interceptors]]` and `[[automations]]`.

  The catalog accepts only the current contract; there are no legacy decoders.
  """

  @type spec :: %{
          kind: :command | :event,
          versions: [String.t()],
          required: [String.t()],
          emitted_by: [String.t()],
          interceptable: boolean(),
          injectable: boolean(),
          doc: String.t()
        }

  @catalog %{
    "interception.requested" => %{
      kind: :event,
      versions: ["1"],
      required: ["source_event_id", "name", "actor", "attempt", "rule", "actor_work_item_id"],
      emitted_by: ["Core"],
      interceptable: false,
      injectable: false,
      doc: "Durable actor request. An actor named human denotes escalation."
    },
    "interception.responded" => %{
      kind: :command,
      versions: ["1"],
      required: ["request_id", "actor", "outcome"],
      emitted_by: ["Actor"],
      interceptable: false,
      injectable: true,
      doc: "Correlated actor result or failure; duplicate and invalid replies are rejected."
    },
    "interception.expired" => %{
      kind: :event,
      versions: ["1"],
      required: ["request_id", "actor", "outcome", "error"],
      emitted_by: ["Core"],
      interceptable: false,
      injectable: false,
      doc: "Configured actor response deadline elapsed; it does not judge task completion."
    },
    "interception.resolved" => %{
      kind: :event,
      versions: ["1"],
      required: ["request_id", "source_event_id", "name", "bindings", "output"],
      emitted_by: ["Core"],
      interceptable: false,
      injectable: false,
      doc: "Persisted actor output for delivery context; the source envelope remains immutable."
    },
    "task.recovery_used" => %{
      kind: :event,
      versions: ["1"],
      required: ["recovery", "reason"],
      emitted_by: ["Runtime"],
      interceptable: false,
      injectable: false,
      doc: "Atomic, idempotent reservation from the Work Item stage recovery budget."
    },
    "task.run_requested" => %{
      kind: :event,
      versions: ["1"],
      required: ["comment", "checkpoint", "reason", "stage"],
      emitted_by: ["Runtime"],
      interceptable: false,
      injectable: false,
      doc: "Durable retry scheduling, replayed if the executor stops before Run activation."
    },
    "task.break" => %{
      kind: :event,
      versions: ["1"],
      required: ["comment", "target", "reviewer", "stage", "target_run_id"],
      emitted_by: ["Runtime"],
      interceptable: false,
      injectable: false,
      doc: "Work exhausted its attempts or explicitly paused; review above or by a human."
    },
    "task.assessment_resolved" => %{
      kind: :event,
      versions: ["1"],
      required: ["request_id", "comment"],
      emitted_by: ["Runtime"],
      interceptable: false,
      injectable: false,
      doc: "A responsible resolved a review or break."
    },
    "task.report_handled" => %{
      kind: :event,
      versions: ["1"],
      required: ["report_id"],
      emitted_by: ["Runtime"],
      interceptable: false,
      injectable: false,
      doc: "Durable cursor for a completion report."
    },
    "task.advanced" => %{
      kind: :event,
      versions: ["1"],
      required: ["from", "to", "checkpoint", "comment"],
      emitted_by: ["Runtime"],
      interceptable: false,
      injectable: false,
      doc: "Responsible approval advances the configured work stage."
    },
    "task.assessment_requested" => %{
      kind: :event,
      versions: ["1"],
      required: ["target", "reviewer", "comment", "stage", "target_run_id"],
      emitted_by: ["Runtime"],
      interceptable: false,
      injectable: false,
      doc: "A closed executor Run awaits its responsible's decision."
    },
    "task.requested" => %{
      kind: :command,
      versions: ["1"],
      required: ["instruction"],
      emitted_by: ["CLI", "Run"],
      interceptable: true,
      injectable: true,
      doc:
        "A task enters the harness (command) or a Run requests cross-lineage work (event with requested_by)."
    },
    "task.resumed" => %{
      kind: :command,
      versions: ["1"],
      required: [],
      emitted_by: ["CLI"],
      interceptable: true,
      injectable: true,
      doc: "Ask for a new attempt of a failed Work Item, from its last checkpoint."
    },
    "task.delegated" => %{
      kind: :event,
      versions: ["1"],
      required: [
        "work_item",
        "comment",
        "child_work_item_id",
        "to_depth",
        "parent_run_id",
        "originating_run_id"
      ],
      emitted_by: ["Run"],
      interceptable: true,
      injectable: false,
      doc: "A Run hands work to a child Execution Node; creates the child Work Item."
    },
    "task.completed" => %{
      kind: :event,
      versions: ["1"],
      required: ["result", "depth"],
      emitted_by: ["Runtime"],
      interceptable: true,
      injectable: false,
      doc: "The responsible approved the final stage; the Runtime completes the Work Item."
    },
    "task.resume_rejected" => %{
      kind: :event,
      versions: ["1"],
      required: ["reason"],
      emitted_by: ["Runtime"],
      interceptable: false,
      injectable: false,
      doc: "A task.resumed command was not eligible (unknown, still open or already completed)."
    },
    "tool.call.requested" => %{
      kind: :event,
      versions: ["1"],
      required: ["tool", "round"],
      emitted_by: ["Run"],
      interceptable: true,
      injectable: false,
      doc: "The model asked for a tool; execution waits for this envelope to be delivered."
    },
    "tool.call.completed" => %{
      kind: :event,
      versions: ["1"],
      required: ["tool", "round", "outcome"],
      emitted_by: ["Run"],
      interceptable: false,
      injectable: false,
      doc: "Tool result and checkpoint of the Run's tool state."
    },
    "policy.loaded" => %{
      kind: :event,
      versions: ["1"],
      required: ["hash"],
      emitted_by: ["Runtime"],
      interceptable: false,
      injectable: false,
      doc:
        "The active policy table changed; pins tool access for subsequent runs. Payload may also include a table snapshot."
    },
    "run.started" => %{
      kind: :event,
      versions: ["1"],
      required: ["attempt", "depth", "agent_id", "agent_kind", "reason", "tools"],
      emitted_by: ["Run"],
      interceptable: false,
      injectable: false,
      doc:
        "A durable attempt begins; ARCHIVE_RUNS row is created from it. The tools field pins granted, negotiable, human, and forbidden bands for the Run."
    },
    "run.completed" => %{
      kind: :event,
      versions: ["1"],
      required: ["outcome"],
      emitted_by: ["Run"],
      interceptable: false,
      injectable: false,
      doc: "The attempt closed successfully."
    },
    "run.failed" => %{
      kind: :event,
      versions: ["1"],
      required: ["reason"],
      emitted_by: ["Run", "Runtime"],
      interceptable: false,
      injectable: false,
      doc:
        "The attempt closed with an error or a crash; the Work Item becomes eligible for resume."
    },
    "model.call.requested" => %{
      kind: :event,
      versions: ["1"],
      required: ["round", "messages", "schemas"],
      emitted_by: ["Run"],
      interceptable: false,
      injectable: false,
      doc:
        "Effective model input, committed before the provider call; event_id identifies the call."
    },
    "model.call.failed" => %{
      kind: :event,
      versions: ["1"],
      required: ["call_id", "round", "reason"],
      emitted_by: ["Run"],
      interceptable: false,
      injectable: false,
      doc: "Provider failure linked to the persisted model request."
    },
    "model.call.completed" => %{
      kind: :event,
      versions: ["1"],
      required: ["round", "outcome"],
      emitted_by: ["Run"],
      interceptable: false,
      injectable: false,
      doc: "One provider round finished; ARCHIVE_MODEL_CALLS row is created from it."
    },
    "delivery.rejected" => %{
      kind: :event,
      versions: ["1"],
      required: ["rejected_event_id", "rejected_type", "interceptor", "reason"],
      emitted_by: ["Core"],
      interceptable: false,
      injectable: false,
      doc:
        "An interceptor blocked the delivery of an accepted envelope; the envelope stays in the log."
    },
    "session.created" => %{
      kind: :command,
      versions: ["1"],
      required: ["session_id"],
      emitted_by: ["CLI"],
      interceptable: false,
      injectable: true,
      doc: "A durable session begins; the log is the session record."
    },
    "workspace.attached" => %{
      kind: :command,
      versions: ["1"],
      required: ["workspace_id"],
      emitted_by: ["CLI"],
      interceptable: true,
      injectable: true,
      doc:
        "A workspace is attached to the session with optional roots, teams, and policy overrides."
    },
    "workspace.detached" => %{
      kind: :command,
      versions: ["1"],
      required: ["workspace_id"],
      emitted_by: ["CLI"],
      interceptable: true,
      injectable: true,
      doc: "A workspace is detached from the session without deleting its history."
    },
    "task.commented" => %{
      kind: :command,
      versions: ["1"],
      required: ["body"],
      emitted_by: ["CLI", "Runtime"],
      interceptable: true,
      injectable: true,
      doc: "A durable comment on a Work Item; kind may be request or response for inbox flows."
    },
    "permission.requested" => %{
      kind: :event,
      versions: ["1"],
      required: ["request_id", "tool"],
      emitted_by: ["Run"],
      interceptable: true,
      injectable: false,
      doc:
        "A Run asks for a tool outside its pinned bands; projects to COMMENTS as a human inbox request."
    },
    "permission.granted" => %{
      kind: :command,
      versions: ["1"],
      required: ["request_id", "kind", "granter"],
      emitted_by: ["Run", "CLI"],
      interceptable: true,
      injectable: true,
      doc:
        "Grants a permission request; kind is temporary or permanent; granter is run:<id>, human:<origin>, or policy."
    },
    "permission.denied" => %{
      kind: :command,
      versions: ["1"],
      required: ["request_id", "reason"],
      emitted_by: ["Run", "CLI", "Runtime"],
      interceptable: false,
      injectable: true,
      doc: "Denies a permission request; reason explains the refusal to the requesting Run."
    },
    "permission.revoked" => %{
      kind: :command,
      versions: ["1"],
      required: ["request_id"],
      emitted_by: ["Run", "CLI"],
      interceptable: true,
      injectable: true,
      doc: "Revokes a previously granted permission for the current task lineage."
    },
    "policy.changed" => %{
      kind: :event,
      versions: ["1"],
      required: [],
      emitted_by: ["CLI"],
      interceptable: false,
      injectable: false,
      doc: "The on-disk policy table changed after a permanent grant or manual edit."
    },
    "inbox.read" => %{
      kind: :command,
      versions: ["1"],
      required: ["id"],
      emitted_by: ["CLI"],
      interceptable: false,
      injectable: true,
      doc: "Marks an inbox comment or task result as read in COMMENTS.read_at."
    }
  }

  def catalog, do: @catalog
  def types, do: @catalog |> Map.keys() |> Enum.sort()
  def spec(type), do: Map.get(@catalog, type)
  def known?(type), do: Map.has_key?(@catalog, type)

  @doc "Events whose consumers can durably defer Run activation or handoff."
  def actor_boundary?(type),
    do:
      type in [
        "task.requested",
        "task.delegated",
        "task.resumed",
        "run.completed",
        "run.failed",
        "task.run_requested",
        "task.advanced",
        "task.assessment_requested",
        "task.break",
        "task.completed"
      ]

  def interceptable?(type), do: match?(%{interceptable: true}, spec(type))
  def injectable?(type), do: match?(%{injectable: true, kind: :command}, spec(type))

  @doc """
  Stable permission request id for a grant-lineage root work item and tool.

  Hashed like node ids: parts joined with `\\0`, SHA-256, lower hex, `req_` + first 16 chars.
  """
  def request_id(grant_root_work_item_id, tool)
      when is_binary(grant_root_work_item_id) and is_binary(tool) do
    [grant_root_work_item_id, tool]
    |> Enum.map(&to_string/1)
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("req_" <> String.slice(&1, 0, 16)))
  end

  @doc """
  Resolve the grant-lineage root for a work item using `WORK_ITEMS.parent_work_item_id`.

  Depth-0 roots and depth-1 tasks under the session root are their own grant roots;
  deeper tasks inherit the nearest depth-1 ancestor's lineage.
  """
  def grant_root_work_item_id(conn, work_item_id) when is_binary(work_item_id) do
    parent = parent_work_item_id(conn, work_item_id)

    cond do
      is_nil(parent) ->
        work_item_id

      is_nil(parent_work_item_id(conn, parent)) ->
        work_item_id

      true ->
        grant_root_work_item_id(conn, parent)
    end
  end

  defp parent_work_item_id(conn, work_item_id) do
    alias Omunculus.EventCore.Store

    case Store.query(conn, "SELECT parent_work_item_id FROM WORK_ITEMS WHERE work_item_id = ?", [
           work_item_id
         ])
         |> List.last() do
      [parent] when is_binary(parent) -> parent
      _ -> nil
    end
  end

  @doc "Validate an envelope against the catalog."
  def validate(%{type: type, kind: kind, schema_version: version, payload: payload}) do
    case spec(type) do
      nil ->
        {:error, {:unknown_event_type, type}}

      spec ->
        cond do
          type == "task.requested" and kind == :event ->
            validate_task_requested_event(version, payload)

          spec.kind != kind ->
            {:error, {:kind_mismatch, type, kind}}

          version not in spec.versions ->
            {:error, {:unsupported_schema_version, type, version}}

          true ->
            case Enum.reject(spec.required, &Map.has_key?(payload, &1)) do
              [] -> if(type == "task.requested", do: :ok, else: validate_handoff(type, payload))
              missing -> {:error, {:missing_payload_fields, type, missing}}
            end
        end
    end
  end

  defp validate_task_requested_event(version, payload) do
    required = ["work_item", "comment", "requested_by", "child_work_item_id"]

    cond do
      version != "1" ->
        {:error, {:unsupported_schema_version, "task.requested", version}}

      true ->
        case Enum.reject(required, &Map.has_key?(payload, &1)) do
          [] -> validate_handoff("task.requested", payload)
          missing -> {:error, {:missing_payload_fields, "task.requested", missing}}
        end
    end
  end

  defp validate_handoff(type, payload) when type in ["task.delegated", "task.requested"] do
    case Omunculus.WorkItem.handoff(payload) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp validate_handoff(_, _), do: :ok

  @doc "Markdown table of the catalog, the source of the table in docs/to-be/event-catalog.md."
  def markdown do
    header =
      "| Tipo | Kind | Payload obrigatório | Emitido por | Interceptável | Injetável |\n|---|---|---|---|---|---|\n"

    rows =
      Enum.map_join(types(), "\n", fn type ->
        s = spec(type)

        "| `#{type}` | #{s.kind} | #{required_cell(s.required)} | #{Enum.join(s.emitted_by, ", ")} | #{yes_no(s.interceptable)} | #{yes_no(s.injectable)} |"
      end)

    header <> rows <> "\n"
  end

  defp required_cell([]), do: "—"
  defp required_cell(fields), do: Enum.map_join(fields, ", ", &"`#{&1}`")
  defp yes_no(true), do: "sim"
  defp yes_no(false), do: "não"
end
