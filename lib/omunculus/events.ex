defmodule Omunculus.Events do
  @moduledoc """
  The event catalog (docs/to-be/event-catalog.md): every envelope type the
  harness accepts, declared once. The Event Core validates each append
  against it; `omunculus events catalog` renders it; the config check uses it
  to validate `[[interceptors]]` and `[[automations]]`.

  Evolving a payload means registering a new `schema_version` here and
  keeping the old one accepted until no consumer declares it.
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
    "task.requested" => %{
      kind: :command,
      versions: ["1"],
      required: ["instruction"],
      emitted_by: ["CLI"],
      interceptable: true,
      injectable: true,
      doc: "A task enters the harness; creates the root Work Item and activates a depth-0 Run."
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
        "instruction",
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
      emitted_by: ["Run"],
      interceptable: true,
      injectable: false,
      doc: "A Run reports its Work Item done; parents waiting on it continue."
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
    "run.started" => %{
      kind: :event,
      versions: ["1"],
      required: ["attempt", "depth", "agent_id", "agent_kind"],
      emitted_by: ["Run"],
      interceptable: false,
      injectable: false,
      doc: "A durable attempt begins; ARCHIVE_RUNS row is created from it."
    },
    "run.completed" => %{
      kind: :event,
      versions: ["1"],
      required: [],
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
    }
  }

  def catalog, do: @catalog
  def types, do: @catalog |> Map.keys() |> Enum.sort()
  def spec(type), do: Map.get(@catalog, type)
  def known?(type), do: Map.has_key?(@catalog, type)

  def interceptable?(type), do: match?(%{interceptable: true}, spec(type))
  def injectable?(type), do: match?(%{injectable: true, kind: :command}, spec(type))

  @doc "Validate an envelope against the catalog."
  def validate(%{type: type, kind: kind, schema_version: version, payload: payload}) do
    case spec(type) do
      nil ->
        {:error, {:unknown_event_type, type}}

      spec ->
        cond do
          spec.kind != kind ->
            {:error, {:kind_mismatch, type, kind}}

          version not in spec.versions ->
            {:error, {:unsupported_schema_version, type, version}}

          true ->
            case Enum.reject(spec.required, &Map.has_key?(payload, &1)) do
              [] -> :ok
              missing -> {:error, {:missing_payload_fields, type, missing}}
            end
        end
    end
  end

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
