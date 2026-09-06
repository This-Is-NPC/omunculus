defmodule Omunculus.CLI.Events do
  @moduledoc """
  The two external ports and the catalog (docs/to-be/event-catalog.md):

  * `omunculus events catalog` renders the catalog module;
  * `omunculus events follow --db f` streams `EVENTS` as NDJSON with a cursor;
  * `omunculus emit <type> --db f --payload json` appends an injectable command;
  * `omunculus config check` validates interceptors and automations.
  """

  alias Omunculus.CLI.Help
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
         {:ok, payload} <- decode_payload(flags["payload"]),
         {:ok, db} <- require_db(flags["db"]) do
      {:ok, core} = EventCore.start_link(path: db)

      envelope =
        Envelope.command(type,
          correlation_id: flags["correlation_id"],
          idempotency_key: flags["idempotency_key"],
          work_item_id: flags["work_item_id"] || Envelope.generate_id("wi"),
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
          IO.puts("interceptors: #{length(checked.interceptors)}")

          Enum.each(checked.interceptors, fn i ->
            IO.puts("  #{i.name} -> #{inspect(i.module)} on #{Enum.join(i.events, ", ")}")
          end)

          IO.puts("automations: #{length(checked.automations)}")

          Enum.each(checked.automations, fn a ->
            IO.puts("  #{a.name} -> #{a.run} on #{Enum.join(a.events, ", ")}")
          end)

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
    with {:ok, db} <- require_db(flags["db"]),
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

  defp require_db(db) when is_binary(db) and db != "", do: {:ok, db}
  defp require_db(_), do: {:error, {:missing_required_arg, "--db"}}

  defp parse_after(nil), do: {:ok, 0}

  defp parse_after(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid_flag_value, "--after", raw}}
    end
  end
end
