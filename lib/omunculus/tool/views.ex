defmodule Omunculus.Tool.Views do
  @moduledoc """
  The views a manifest declares, as `[views.<key>]` tables, and their
  hydration before a call. A view names a `source`, where it starts
  (`from`, a list of anchors, the first present wins) and the options its
  source takes; the call receives what the source reads under `<key>` in
  `in.view`. A view whose anchors are all absent is left out.

  Anchors: `work`, `run`, `request`, `inbox` and `prompt` are those of the
  call; `latest_run` is the most recently started run; `args.<name>` is a
  string argument of the call.

  Sources:

  - `works`: `relation` `self` (default), `parent` or `children`; from
    `work` (default) or `args.<name>`, which needs `within =
    "descendants"` and then reads only a work below the call's own.
    Children take `state` (a list) and `since = "last_run"` (changed after
    the work's last closed run finished). `include` adds to each work its
    `last_comment`, its `comments` or its closed `runs` with their record:
    the opening message, the assembled prompt and the events.
  - `comments`: of the first of `from` among `work`, `request`, `inbox`
    (default all three, in that order).
  - `runs`: `relation` `last_closed` (from `work`) or `opener` (the run
    that opened the call's `request`), with its record.
  - `events`: `relation` `run`, the events of the call's run so far, or
    `cause`, the event that made the call's run due.
  - `requests`: from `args.request_id` then `request` (default).
  - `prompts`: `relation` `message`, the prompt that opened the run, or
    `assembled`, the assembled prompt of the run named by `from` (default
    `args.run`, then `latest_run`).
  - `inbox`: the unread inbox of the project, or of the call's work with
    `from = ["work"]`.
  - `counter`: the bench counter of the project.
  - `catalog`, `workspaces`, `agents`, `paths`, `grant_scopes`, `skills`:
    computed by the harness for the call, each only when a view asks for
    it, through a function of the view in `computed`. `agents` takes
    `include = ["tools"]`, which gives each agent with the model tools it
    has; when the depth below has a workflow, it is that workflow, its
    `stages` each a `name` and an `agent`. `skills` are the Agent Skills the call's run has, each its `name`,
    `description` and `dir`.

  Every read is of the call's conversation, through those relations only;
  tools never open the store.
  """

  alias Omunculus.Store

  @type spec :: %{
          key: String.t(),
          source: String.t(),
          from: [String.t()],
          relation: String.t() | nil,
          states: [String.t()] | nil,
          since_last_run: boolean,
          include: [String.t()],
          within: String.t() | nil
        }

  @computed ~w(catalog workspaces agents paths grant_scopes skills)
  @work_states ~w(open waiting done cancelled)
  @work_includes %{"last_comment" => :last_comment, "comments" => :comments, "runs" => :runs}
  @comment_targets %{"work" => :work, "request" => :request, "inbox" => :inbox}

  @doc "Parses the `views` table of a manifest."
  @spec parse(term) :: {:ok, [spec]} | {:error, term}
  def parse(views) when is_map(views) do
    views
    |> Enum.sort_by(fn {key, _table} -> key end)
    |> Enum.reduce_while({:ok, []}, fn {key, table}, {:ok, acc} ->
      case parse_view(key, table) do
        {:ok, spec} -> {:cont, {:ok, acc ++ [spec]}}
        {:error, reason} -> {:halt, {:error, {:views, key, reason}}}
      end
    end)
  end

  def parse(_views), do: {:error, {:views, :not_a_table}}

  defp parse_view(key, %{"source" => source} = table) when is_binary(source) do
    spec = %{
      key: key,
      source: source,
      from: [],
      relation: nil,
      states: nil,
      since_last_run: false,
      include: [],
      within: nil
    }

    with {:ok, from} <- string_list(table, "from"),
         {:ok, spec} <- source_spec(source, Map.delete(table, "source"), spec) do
      check_anchors(if from == [], do: spec, else: %{spec | from: from})
    end
  end

  defp parse_view(_key, _table), do: {:error, :missing_source}

  defp source_spec("works", table, spec) do
    with :ok <- only_keys(table, ~w(from relation state since include within)),
         {:ok, relation} <- one_of(table, "relation", ~w(self parent children), "self"),
         {:ok, states} <- subset(table, "state", @work_states),
         {:ok, since} <- one_of(table, "since", ["last_run"], nil),
         {:ok, include} <- subset(table, "include", Map.keys(@work_includes)),
         {:ok, within} <- one_of(table, "within", ["descendants"], nil),
         :ok <- children_only(relation, states, since) do
      {:ok,
       %{
         spec
         | from: ["work"],
           relation: relation,
           states: states,
           since_last_run: since == "last_run",
           include: include || [],
           within: within
       }}
    end
  end

  defp source_spec("comments", table, spec) do
    with :ok <- only_keys(table, ~w(from)), do: {:ok, %{spec | from: ~w(work request inbox)}}
  end

  defp source_spec("runs", table, spec) do
    with :ok <- only_keys(table, ~w(relation)),
         {:ok, relation} <- one_of(table, "relation", ~w(last_closed opener), nil),
         :ok <- required(relation, :relation) do
      from = if relation == "last_closed", do: ["work"], else: ["request"]
      {:ok, %{spec | from: from, relation: relation}}
    end
  end

  defp source_spec("events", table, spec) do
    with :ok <- only_keys(table, ~w(relation)),
         {:ok, relation} <- one_of(table, "relation", ~w(run cause), nil),
         :ok <- required(relation, :relation) do
      {:ok, %{spec | from: ["run"], relation: relation}}
    end
  end

  defp source_spec("requests", table, spec) do
    with :ok <- only_keys(table, ~w(from)),
         do: {:ok, %{spec | from: ["args.request_id", "request"]}}
  end

  defp source_spec("prompts", table, spec) do
    with {:ok, relation} <- one_of(table, "relation", ~w(message assembled), nil),
         :ok <- required(relation, :relation),
         :ok <-
           only_keys(
             table,
             if(relation == "assembled", do: ~w(from relation), else: ~w(relation))
           ) do
      from = if relation == "message", do: ["prompt"], else: ["args.run", "latest_run"]
      {:ok, %{spec | from: from, relation: relation}}
    end
  end

  defp source_spec("inbox", table, spec) do
    with :ok <- only_keys(table, ~w(from)), do: {:ok, spec}
  end

  defp source_spec("agents", table, spec) do
    with :ok <- only_keys(table, ~w(include)),
         {:ok, include} <- subset(table, "include", ["tools"]),
         do: {:ok, %{spec | include: include || []}}
  end

  defp source_spec(source, table, spec) when source in ["counter" | @computed] do
    with :ok <- only_keys(table, []), do: {:ok, spec}
  end

  defp source_spec(source, _table, _spec), do: {:error, {:unknown_source, source}}

  # The anchors a source accepts once `from` is known.
  defp check_anchors(%{source: "works", from: from, within: within} = spec) do
    cond do
      from == ["work"] and is_nil(within) -> {:ok, spec}
      Enum.all?(from, &args_anchor?/1) and within == "descendants" -> {:ok, spec}
      true -> {:error, {:anchors, from}}
    end
  end

  defp check_anchors(%{source: "comments", from: from} = spec),
    do: anchors_within(spec, from, ~w(work request inbox))

  defp check_anchors(%{source: "requests", from: from} = spec) do
    if Enum.all?(from, &(args_anchor?(&1) or &1 == "request")),
      do: {:ok, spec},
      else: {:error, {:anchors, from}}
  end

  defp check_anchors(%{source: "prompts", relation: "assembled", from: from} = spec) do
    if Enum.all?(from, &(args_anchor?(&1) or &1 == "latest_run")),
      do: {:ok, spec},
      else: {:error, {:anchors, from}}
  end

  defp check_anchors(%{source: "inbox", from: from} = spec),
    do: anchors_within(spec, from, ["work"])

  defp check_anchors(%{source: source} = spec) when source in ~w(runs events prompts),
    do: {:ok, spec}

  defp check_anchors(%{from: []} = spec), do: {:ok, spec}
  defp check_anchors(%{from: from}), do: {:error, {:anchors, from}}

  defp anchors_within(spec, from, allowed) do
    if Enum.all?(from, &(&1 in allowed)), do: {:ok, spec}, else: {:error, {:anchors, from}}
  end

  defp args_anchor?("args." <> name), do: name != ""
  defp args_anchor?(_anchor), do: false

  defp children_only("children", _states, _since), do: :ok
  defp children_only(_relation, nil, nil), do: :ok
  defp children_only(_relation, _states, _since), do: {:error, :children_only}

  defp required(nil, name), do: {:error, {:missing, name}}
  defp required(_value, _name), do: :ok

  defp only_keys(table, allowed) do
    case Map.keys(table) -- allowed do
      [] -> :ok
      [key | _] -> {:error, {:unknown_key, key}}
    end
  end

  defp one_of(table, key, allowed, default) do
    case Map.fetch(table, key) do
      :error -> {:ok, default}
      {:ok, value} -> if value in allowed, do: {:ok, value}, else: {:error, {:invalid, key}}
    end
  end

  defp subset(table, key, allowed) do
    case Map.fetch(table, key) do
      :error ->
        {:ok, nil}

      {:ok, values} when is_list(values) ->
        if values != [] and Enum.all?(values, &(&1 in allowed)),
          do: {:ok, values},
          else: {:error, {:invalid, key}}

      {:ok, _value} ->
        {:error, {:invalid, key}}
    end
  end

  defp string_list(table, key) do
    case Map.get(table, key, []) do
      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")),
          do: {:ok, list},
          else: {:error, {:invalid, key}}

      _value ->
        {:error, {:invalid, key}}
    end
  end

  @doc """
  Reads every view of `specs` for one call. `scope` holds the call's
  anchors (`run_id`, `work_id`, `request_id`, `inbox_id`, `prompt_id`,
  `args`) and `computed`, the harness's functions by source name, each
  given the view it computes for.
  """
  @spec hydrate(Omunculus.Store.Connection.t(), [spec], map) :: {:ok, map} | {:error, term}
  def hydrate(conn, specs, scope) do
    Enum.reduce_while(specs, {:ok, %{}}, fn spec, {:ok, acc} ->
      case read(conn, spec, scope) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, spec.key, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp read(_conn, %{source: source} = spec, scope) when source in @computed,
    do: {:ok, Map.fetch!(scope.computed, source).(spec)}

  defp read(conn, %{source: "counter"}, _scope), do: Store.counter(conn)
  defp read(conn, %{source: "inbox", from: []}, _scope), do: Store.unread_inbox(conn, nil)

  defp read(conn, %{source: "prompts", relation: "assembled", from: from}, scope) do
    with {:ok, run} <- assembled_run(conn, from, scope) do
      case run.prompt_id do
        id when is_binary(id) and id != "" -> Store.view(conn, "prompt", id)
        _none -> {:error, :no_assembled}
      end
    end
  end

  defp read(conn, spec, scope) do
    case anchor(conn, spec.from, scope) do
      nil -> :skip
      {anchor, id} -> read_from(conn, spec, anchor, id, scope)
    end
  end

  defp read_from(conn, %{source: "works"} = spec, anchor, id, scope) do
    with :ok <- inside(conn, spec, anchor, id, scope),
         {:ok, works} <- works(conn, spec, id) do
      include(conn, works, spec.include)
    end
  end

  defp read_from(conn, %{source: "comments"}, anchor, id, _scope),
    do: Store.comments(conn, Map.fetch!(@comment_targets, anchor), id)

  defp read_from(conn, %{source: "runs", relation: "last_closed"}, _anchor, id, _scope),
    do: Store.last_closed_run(conn, id)

  defp read_from(conn, %{source: "runs", relation: "opener"}, _anchor, id, _scope),
    do: Store.opener_run(conn, id)

  defp read_from(conn, %{source: "events", relation: "run"}, _anchor, id, _scope),
    do: Store.replay(conn, {:run, id})

  defp read_from(conn, %{source: "events", relation: "cause"}, _anchor, id, _scope) do
    with {:ok, run} <- Store.view(conn, "run", id) do
      if run && run.cause_id, do: Store.view(conn, "event", run.cause_id), else: {:ok, nil}
    end
  end

  defp read_from(conn, %{source: "requests"}, _anchor, id, _scope),
    do: Store.view(conn, "request", id)

  defp read_from(conn, %{source: "prompts"}, _anchor, id, _scope),
    do: Store.view(conn, "prompt", id)

  defp read_from(conn, %{source: "inbox"}, _anchor, id, _scope),
    do: Store.unread_inbox(conn, id)

  defp anchor(conn, from, scope) do
    Enum.find_value(from, fn anchor ->
      case anchor_id(conn, anchor, scope) do
        id when is_binary(id) and id != "" -> {anchor, id}
        _absent -> nil
      end
    end)
  end

  defp anchor_id(_conn, "args." <> name, scope), do: Map.get(scope.args || %{}, name)
  defp anchor_id(_conn, "work", scope), do: scope.work_id
  defp anchor_id(_conn, "run", scope), do: scope.run_id
  defp anchor_id(_conn, "request", scope), do: scope.request_id
  defp anchor_id(_conn, "inbox", scope), do: scope.inbox_id
  defp anchor_id(_conn, "prompt", scope), do: scope.prompt_id

  defp anchor_id(conn, "latest_run", _scope) do
    case Store.latest_run(conn) do
      {:ok, %{id: id}} -> id
      _none -> nil
    end
  end

  # The run whose assembled prompt `prompts` with `assembled` reads.
  defp assembled_run(conn, from, scope) do
    case anchor(conn, from, scope) do
      nil ->
        {:error, :no_runs}

      {_anchor, id} ->
        case Store.view(conn, "run", id) do
          {:ok, nil} -> {:error, {:unknown_run, id}}
          other -> other
        end
    end
  end

  defp inside(_conn, %{within: nil}, _anchor, _id, _scope), do: :ok

  defp inside(conn, %{within: "descendants"}, _anchor, id, scope) do
    if is_binary(scope.work_id) and Store.descends?(conn, id, scope.work_id),
      do: :ok,
      else: {:error, {:outside, id}}
  end

  defp works(conn, %{relation: "self"}, id), do: Store.view(conn, "work", id)

  defp works(conn, %{relation: "parent"}, id) do
    with {:ok, work} <- Store.view(conn, "work", id) do
      if work && work.parent_id, do: Store.view(conn, "work", work.parent_id), else: {:ok, nil}
    end
  end

  defp works(conn, %{relation: "children"} = spec, id),
    do: Store.children(conn, id, spec.states, spec.since_last_run)

  defp include(_conn, works, []), do: {:ok, works}
  defp include(_conn, nil, _include), do: {:ok, nil}

  defp include(conn, works, include) when is_list(works) do
    Enum.reduce_while(works, {:ok, []}, fn work, {:ok, acc} ->
      case include(conn, work, include) do
        {:ok, work} -> {:cont, {:ok, acc ++ [work]}}
        error -> {:halt, error}
      end
    end)
  end

  defp include(conn, work, include) do
    Enum.reduce_while(include, {:ok, work}, fn field, {:ok, work} ->
      case include_field(conn, work, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(work, Map.fetch!(@work_includes, field), value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp include_field(conn, work, "last_comment") do
    with {:ok, comments} <- Store.comments(conn, :work, work.id), do: {:ok, List.last(comments)}
  end

  defp include_field(conn, work, "comments"), do: Store.comments(conn, :work, work.id)
  defp include_field(conn, work, "runs"), do: Store.closed_runs(conn, work.id)
end
