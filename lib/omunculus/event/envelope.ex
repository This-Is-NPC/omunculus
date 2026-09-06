defmodule Omunculus.Event.Envelope do
  @moduledoc """
  Command/event envelope as specified in docs/to-be/event-model.md.

  `session_id` and `workspace_id` are reserved per docs/to-be/recommendations.md
  and are always nullable in this spike.
  """

  @kinds [:command, :event]
  @schema_version "1"

  @enforce_keys [
    :event_id,
    :kind,
    :type,
    :schema_version,
    :occurred_at,
    :correlation_id,
    :payload
  ]
  defstruct event_id: nil,
            kind: nil,
            type: nil,
            schema_version: @schema_version,
            sequence: nil,
            occurred_at: nil,
            correlation_id: nil,
            causation_id: nil,
            idempotency_key: nil,
            session_id: nil,
            workspace_id: nil,
            project_id: nil,
            work_item_id: nil,
            run_id: nil,
            payload: %{}

  @type t :: %__MODULE__{}

  @doc "Build a command envelope. A command starts a correlation unless one is given."
  def command(type, attrs \\ []), do: new(:command, type, attrs)

  @doc "Build an event envelope. Events must carry a correlation and normally a causation."
  def event(type, attrs \\ []), do: new(:event, type, attrs)

  def new(kind, type, attrs) when kind in @kinds and is_binary(type) do
    attrs = Map.new(attrs)
    event_id = attrs[:event_id] || generate_id("evt")

    %__MODULE__{
      event_id: event_id,
      kind: kind,
      type: type,
      schema_version: attrs[:schema_version] || @schema_version,
      sequence: nil,
      occurred_at: attrs[:occurred_at] || DateTime.to_iso8601(DateTime.utc_now()),
      correlation_id: attrs[:correlation_id] || generate_id("corr"),
      causation_id: attrs[:causation_id],
      idempotency_key: attrs[:idempotency_key],
      session_id: attrs[:session_id],
      workspace_id: attrs[:workspace_id],
      project_id: attrs[:project_id],
      work_item_id: attrs[:work_item_id],
      run_id: attrs[:run_id],
      payload: normalize_payload(attrs[:payload] || %{})
    }
  end

  @doc "Validate the structural invariants of an envelope before append."
  def validate(%__MODULE__{} = env) do
    cond do
      env.kind not in @kinds ->
        {:error, {:invalid_kind, env.kind}}

      not (is_binary(env.type) and env.type != "") ->
        {:error, {:invalid_type, env.type}}

      not is_binary(env.event_id) ->
        {:error, {:invalid_event_id, env.event_id}}

      not is_binary(env.correlation_id) ->
        {:error, {:invalid_correlation_id, env.correlation_id}}

      not is_binary(env.schema_version) ->
        {:error, {:invalid_schema_version, env.schema_version}}

      not (is_nil(env.causation_id) or is_binary(env.causation_id)) ->
        {:error, :invalid_causation_id}

      not is_map(env.payload) ->
        {:error, :invalid_payload}

      env.kind == :event and is_nil(env.causation_id) ->
        {:error, :event_requires_causation}

      true ->
        :ok
    end
  end

  def validate(_), do: {:error, :not_an_envelope}

  @doc """
  Content hash over everything except `sequence`. Two envelopes with the same
  `event_id` and the same hash are the same envelope (idempotent redelivery).
  """
  def content_hash(%__MODULE__{} = env) do
    env
    |> Map.from_struct()
    |> Map.drop([:sequence])
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Deterministic JSON: maps are emitted with keys sorted."
  def canonical_json(term), do: term |> sort_keys() |> Jason.encode!()

  defp sort_keys(%__MODULE__{} = s), do: s |> Map.from_struct() |> sort_keys()

  defp sort_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), sort_keys(v)} end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)

  defp sort_keys(atom) when is_atom(atom) and not is_nil(atom) and atom not in [true, false],
    do: Atom.to_string(atom)

  defp sort_keys(other), do: other

  @doc "Payloads are always JSON-shaped: string keys, JSON scalars."
  def normalize_payload(payload) when is_map(payload) do
    payload |> Jason.encode!() |> Jason.decode!()
  end

  def generate_id(prefix) do
    prefix <> "-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  @columns ~w(sequence event_id kind type schema_version payload occurred_at correlation_id
              causation_id idempotency_key session_id workspace_id project_id work_item_id run_id)a

  def columns, do: @columns

  @doc "Row values in `columns/0` order (payload JSON encoded, kind as string)."
  def to_row(%__MODULE__{} = env) do
    Enum.map(@columns, fn
      :payload -> Jason.encode!(env.payload)
      :kind -> Atom.to_string(env.kind)
      col -> Map.fetch!(env, col)
    end)
  end

  def from_row(row) when is_list(row) do
    map = Enum.zip(@columns, row) |> Map.new()

    struct!(__MODULE__, %{
      map
      | payload: Jason.decode!(map.payload),
        kind: String.to_existing_atom(map.kind)
    })
  end

  def to_map(%__MODULE__{} = env) do
    env |> Map.from_struct() |> Map.update!(:kind, &Atom.to_string/1)
  end
end
