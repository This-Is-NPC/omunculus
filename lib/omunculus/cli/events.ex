defmodule Omunculus.CLI.Events do
  @moduledoc """
  The two external ports and the catalog (docs/to-be/event-catalog.md):

  * `omunculus events catalog` renders the catalog module;
  * `omunculus events follow --db f` streams `EVENTS` as NDJSON with a cursor;
  * `omunculus emit <type> --db f --payload json` appends an injectable command;
  * `omunculus config check` validates interceptors and automations.
  """

  alias Omunculus.CLI.Help
  alias Omunculus.CLI.Inbox
  alias Omunculus.CLI.Session
  alias Omunculus.{Config, Events}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore

  @poll_ms 250

  def events(%{args: args, flags: flags}) do
    case args[:action] do
      "catalog" ->
        IO.write(Events.markdown())
        0

      "follow" ->
        follow(flags)

      other ->
        IO.puts(:stderr, Help.usage_error({:invalid_flag_value, "events", other || ""}))
        2
    end
  end

  def emit(%{args: args, flags: flags}, _env) do
    type = args[:type]

    with :ok <- injectable(type),
         {:ok, db} <- Session.db_path(flags),
         {:ok, payload} <- decode_payload(flags["payload"]),
         {:ok, core} <- open_core(db),
         {:ok, payload, attrs} <- enrich_emit(type, flags, payload, core) do
      envelope =
        Envelope.command(type,
          correlation_id: flags["correlation_id"] || attrs[:correlation_id],
          idempotency_key: flags["idempotency_key"],
          work_item_id:
            flags["work_item_id"] || attrs[:work_item_id] || Envelope.generate_id("wi"),
          session_id: attrs[:session_id],
          workspace_id: attrs[:workspace_id],
          payload: payload
        )

      result = EventCore.append(core, envelope)
      GenServer.stop(core)

      case result do
        {:ok, stored} ->
          IO.puts(Jason.encode!(Envelope.to_map(stored)))
          0

        {:error, reason} ->
          IO.puts(:stderr, "error: emit rejected: #{inspect(reason)}")
          1
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, Help.usage_error(reason))
        2
    end
  end

  def config(%{args: args, flags: flags}, env) do
    case args[:action] do
      "check" ->
        with {:ok, config} <-
               Config.load(cwd: File.cwd!(), config_file: flags["config"], env: env),
             {:ok, checked} <- Config.check(config) do
          IO.puts("agents: #{map_size(config.agents)}")
          IO.puts("teams: #{map_size(config.teams)}")
          IO.puts("workspaces: #{map_size(config.workspaces)}")
          IO.puts("profiles: #{map_size(config.presets)}")

          IO.puts(
            "policy.depth: #{config.policy |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"
          )

          IO.puts("interceptors: #{length(checked.interceptors)}")

          Enum.each(checked.interceptors, fn i ->
            IO.puts(
              "  #{i.name} -> #{inspect(i[:agent] || i[:actor] || i.module)} on #{Enum.join(i.events, ", ")}"
            )
          end)

          IO.puts("automations: #{length(checked.automations)}")

          Enum.each(checked.automations, fn a ->
            IO.puts("  #{a.name} -> #{a.run} on #{Enum.join(a.events, ", ")}")
          end)

          print_policy_table(checked.policy)

          IO.puts("")

          0
        else
          {:error, reason} ->
            IO.puts(:stderr, "error: config invalid: #{inspect(reason)}")
            1
        end

      other ->
        IO.puts(:stderr, Help.usage_error({:invalid_flag_value, "config", other || ""}))
        2
    end
  end

  # --- follow ---------------------------------------------------------------------

  defp follow(flags) do
    with {:ok, db} <- Session.db_path(flags),
         {:ok, after_seq} <- parse_after(flags["after"]) do
      types = flags["types"]
      {:ok, core} = EventCore.start_link(path: db)
      last = dump(core, after_seq, types)

      if flags["once"] do
        GenServer.stop(core)
        0
      else
        # Other processes may append to the same file: poll by sequence.
        loop(core, last, types)
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, Help.usage_error(reason))
        2
    end
  end

  defp loop(core, last, types) do
    Process.sleep(@poll_ms)
    loop(core, dump(core, last, types), types)
  end

  defp dump(core, after_seq, types) do
    core
    |> EventCore.stream(after_seq)
    |> Enum.reduce(after_seq, fn env, _ ->
      if is_nil(types) or env.type in types, do: IO.puts(Jason.encode!(Envelope.to_map(env)))
      env.sequence
    end)
  end

  # --- parsing ---------------------------------------------------------------------

  defp injectable(type) do
    cond do
      not is_binary(type) or type == "" -> {:error, {:missing_required_arg, "type"}}
      not Events.known?(type) -> {:error, {:unknown_event_type, type}}
      not Events.injectable?(type) -> {:error, {:not_injectable, type}}
      true -> :ok
    end
  end

  defp decode_payload(nil), do: {:ok, %{}}

  defp decode_payload(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, {:invalid_flag_value, "--payload", raw}}
    end
  end

  defp open_core(db) do
    {:ok, core} = EventCore.start_link(path: db)
    {:ok, core}
  end

  defp enrich_emit("interception.responded", flags, payload, core) do
    id = flags["request_id"] || payload["request_id"]

    case EventCore.fetch(core, id) do
      {:ok, %{type: "interception.requested"} = req} ->
        {:ok, Map.put(payload, "request_id", id),
         %{
           session_id: req.session_id,
           work_item_id: req.work_item_id,
           correlation_id: req.correlation_id,
           workspace_id: req.workspace_id
         }}

      _ ->
        {:error, {:unknown_interception_request, id}}
    end
  end

  defp enrich_emit(type, flags, payload, core) do
    request_id = flags["request_id"]

    if is_binary(request_id) and request_id != "" do
      case Inbox.lookup_request_for_emit(core, request_id) do
        nil ->
          {:error, {:unknown_permission_request, request_id}}

        req ->
          payload =
            payload
            |> Map.put("request_id", payload["request_id"] || request_id)
            |> Inbox.fill_grant_defaults(type)

          {:ok, payload,
           %{
             session_id: req.session_id,
             work_item_id: req.work_item_id,
             correlation_id: req.correlation_id,
             workspace_id: req.workspace_id
           }}
      end
    else
      {:ok, payload,
       %{session_id: nil, work_item_id: nil, correlation_id: nil, workspace_id: nil}}
    end
  end

  defp print_policy_table(table) when is_map(table) do
    table
    |> Enum.sort_by(fn {{profile, depth, workspace}, _bands} -> {profile, depth, workspace} end)
    |> Enum.each(fn {{profile, depth, workspace}, bands} ->
      IO.puts("profile=#{profile} depth=#{depth} workspace=#{workspace}")
      print_policy_band("granted", bands["granted"])
      print_policy_band("negotiable", bands["negotiable"])
      print_policy_band("human", bands["human"])
      print_policy_band("forbidden", bands["forbidden"])
    end)
  end

  defp print_policy_band(label, names) do
    values =
      case names do
        [] -> "—"
        list -> Enum.join(list, " ")
      end

    IO.puts("  #{label} #{values}")
  end

  defp parse_after(nil), do: {:ok, 0}

  defp parse_after(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid_flag_value, "--after", raw}}
    end
  end
end
