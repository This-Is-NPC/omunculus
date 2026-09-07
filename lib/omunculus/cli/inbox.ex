defmodule Omunculus.CLI.Inbox do
  @moduledoc false

  alias Omunculus.CLI.{Help, Session}
  alias Omunculus.{Config, EventCore}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime
  alias Omunculus.Runtime.Permission, as: RuntimePermission
  alias Omunculus.Runtime.SpikeAgents

  @delivery_ms 100

  def inbox(%{args: args, flags: flags}, env) do
    case args[:action] do
      nil -> list(flags)
      "reply" -> reply(args, flags, env)
      "read" -> read(args, flags)
      action -> usage({:unknown_inbox_action, action})
    end
  end

  defp list(flags) do
    with {:ok, db} <- Session.db_path(flags) do
      {:ok, core} = EventCore.start_link(path: db)

      try do
        print_permission_requests(core)
        print_unread_results(core)
        0
      after
        GenServer.stop(core)
      end
    else
      {:error, reason} -> usage(reason)
    end
  end

  defp reply(args, flags, env) do
    request_id = args[:id]

    with {:ok, db} <- Session.db_path(flags),
         true <-
           (is_binary(request_id) and request_id != "") or
             {:error, {:missing_required_arg, "request_id"}},
         {:ok, mode} <- reply_mode(args, flags),
         {:ok, core0} <- open_core(db),
         {:ok, req} <- find_request(core0, request_id) do
      GenServer.stop(core0)

      with {:ok, envelope} <- build_reply_envelope(mode, req, args, flags, env) do
        deliver_reply(db, flags, env, envelope, mode)
      end
    else
      {:error, reason} -> usage(reason)
      false -> usage({:missing_required_arg, "request_id"})
    end
  end

  defp read(%{id: id}, flags) when is_binary(id) and id != "" do
    with {:ok, db} <- Session.db_path(flags),
         {:ok, core} <- open_core(db) do
      envelope =
        Envelope.command("inbox.read",
          idempotency_key: "inbox-read:#{id}",
          payload: %{id: id}
        )

      {:ok, _} = EventCore.append(core, envelope)
      {:ok, projector} = Projector.start_link(core: core)
      :ok = Projector.sync(projector)
      GenServer.stop(projector)
      GenServer.stop(core)
      0
    else
      {:error, reason} -> usage(reason)
    end
  end

  defp read(_, _), do: usage({:missing_required_arg, "id"})

  defp print_permission_requests(core) do
    RuntimePermission.open_permission_requests(core)
    |> Enum.group_by(fn env ->
      {
        env.payload["workspace"] || env.workspace_id || "default",
        env.payload["tool"],
        env.payload["request_id"]
      }
    end)
    |> Enum.sort_by(fn {{ws, tool, req_id}, _} -> {ws, tool, req_id} end)
    |> Enum.each(fn {{workspace, tool, request_id}, envs} ->
      env = List.first(envs)
      waiting = RuntimePermission.waiting_for_request(core, request_id) |> length()
      task = work_item_instruction(core, env.work_item_id)
      type = env.payload["arbiter"] || "human"

      IO.puts(
        "permission workspace=#{workspace} tool=#{tool} request_id=#{request_id} type=#{type} task=#{inspect(task)} waiting=#{waiting}"
      )
    end)
  end

  defp print_unread_results(core) do
    EventCore.query(
      core,
      """
      SELECT c.comment_id, c.work_item_id, c.body
      FROM COMMENTS c
      JOIN WORK_ITEMS w ON w.work_item_id = c.work_item_id
      WHERE c.kind = 'result' AND c.read_at IS NULL AND w.parent_work_item_id IS NULL
      ORDER BY c.created_at, c.comment_id
      """,
      []
    )
    |> Enum.each(fn [comment_id, work_item_id, body] ->
      IO.puts("result id=#{comment_id} work_item=#{work_item_id} body=#{inspect(body || "")}")
    end)
  end

  defp reply_mode(args, flags) do
    grant? = flags["grant"] == true
    deny? = flags["deny"] == true
    text? = is_binary(args[:message]) and String.trim(args[:message]) != ""

    case {grant?, deny?, text?} do
      {true, false, false} -> {:ok, :grant}
      {false, true, false} -> {:ok, :deny}
      {false, false, true} -> {:ok, {:comment, String.trim(args[:message])}}
      {false, false, false} -> {:error, :inbox_reply_mode_required}
      _ -> {:error, :inbox_reply_mode_conflict}
    end
  end

  defp build_reply_envelope(:grant, req, _args, flags, env) do
    permanent? = flags["permanent"] == true
    kind = if permanent?, do: "permanent", else: "temporary"
    request_id = req.payload["request_id"]

    with :ok <- maybe_patch_policy(req, flags, env, permanent?) do
      {:ok,
       Envelope.command("permission.granted",
         session_id: req.session_id,
         workspace_id: req.workspace_id,
         correlation_id: req.correlation_id,
         work_item_id: req.work_item_id,
         idempotency_key: "inbox-grant:#{request_id}",
         payload: %{
           request_id: request_id,
           kind: kind,
           granter: human_granter()
         }
       )}
    end
  end

  defp build_reply_envelope(:deny, req, _args, flags, _env) do
    reason = flags["reason"] || "denied"
    request_id = req.payload["request_id"]

    {:ok,
     Envelope.command("permission.denied",
       session_id: req.session_id,
       workspace_id: req.workspace_id,
       correlation_id: req.correlation_id,
       work_item_id: req.work_item_id,
       idempotency_key: "inbox-deny:#{request_id}",
       payload: %{request_id: request_id, reason: reason}
     )}
  end

  defp build_reply_envelope({:comment, body}, req, _args, _flags, _env) do
    {:ok,
     Envelope.command("task.commented",
       session_id: req.session_id,
       workspace_id: req.workspace_id,
       correlation_id: req.correlation_id,
       work_item_id: req.work_item_id,
       idempotency_key: "inbox-comment:#{req.payload["request_id"]}",
       payload: %{body: body, kind: "response"}
     )}
  end

  defp maybe_patch_policy(_req, _flags, _env, false), do: :ok

  defp maybe_patch_policy(req, flags, env, true) do
    workspace = req.payload["workspace"] || req.workspace_id
    tool = req.payload["tool"]
    path = config_path(flags, env)

    with true <-
           (is_binary(workspace) and workspace != "") or {:error, {:missing_workspace, workspace}},
         true <- (is_binary(tool) and tool != "") or {:error, {:missing_tool, tool}},
         true <- (is_binary(path) and File.exists?(path)) or {:error, {:missing_config, path}} do
      Omunculus.CLI.Inbox.PolicyPatch.grant_tool(path, workspace, tool)
    end
  end

  defp deliver_reply(db, flags, env, envelope, mode) do
    with {:ok, core} <- open_core(db),
         {:ok, projector} <- Projector.start_link(core: core),
         {:ok, runtime} <- start_runtime(core, flags, env) do
      {:ok, stored} = EventCore.append(core, envelope)
      _ = maybe_append_policy_changed(core, stored, mode)

      :ok = Projector.sync(projector)
      Process.sleep(@delivery_ms)
      GenServer.stop(runtime)
      GenServer.stop(projector)
      GenServer.stop(core)
      0
    else
      {:error, reason} -> usage(reason)
    end
  end

  defp maybe_append_policy_changed(core, envelope, :grant) do
    if envelope.payload["kind"] == "permanent" do
      EventCore.append(
        core,
        Envelope.event("policy.changed",
          session_id: envelope.session_id,
          workspace_id: envelope.workspace_id,
          correlation_id: envelope.correlation_id,
          work_item_id: envelope.work_item_id,
          causation_id: envelope.event_id,
          idempotency_key: "policy-changed:#{envelope.payload["request_id"]}"
        )
      )
    else
      :ok
    end
  end

  defp maybe_append_policy_changed(_core, _envelope, _mode), do: :ok

  defp start_runtime(core, flags, env) do
    with {:ok, config} <- Config.load(cwd: File.cwd!(), config_file: flags["config"], env: env) do
      Runtime.start_link(
        core: core,
        max_depth: max_depth(config),
        agents: SpikeAgents.resolver(),
        run_opts: [delegation_timeout: 600_000],
        config: runtime_config(flags, env)
      )
    end
  end

  defp runtime_config(flags, env) do
    [
      cwd: File.cwd!(),
      config_file: flags["config"],
      env: env
    ]
  end

  defp max_depth(config) do
    depths =
      (config.policy || %{})
      |> Map.keys()
      |> Enum.map(&String.to_integer(to_string(&1)))
      |> Enum.sort(:desc)

    case depths do
      [] -> 1
      [max | _] -> max
    end
  end

  defp find_request(core, request_id) do
    case Enum.find(RuntimePermission.open_permission_requests(core), fn env ->
           env.payload["request_id"] == request_id
         end) do
      nil ->
        case lookup_request_event(core, request_id) do
          nil -> {:error, {:unknown_permission_request, request_id}}
          _env -> {:error, {:permission_request_closed, request_id}}
        end

      env ->
        {:ok, env}
    end
  end

  defp lookup_request_event(core, request_id) do
    EventCore.stream(core, 0, type: "permission.requested")
    |> Enum.find(&(get_in(&1.payload, ["request_id"]) == request_id))
  end

  defp work_item_instruction(core, work_item_id) do
    case EventCore.query(core, "SELECT instruction FROM WORK_ITEMS WHERE work_item_id = ?", [
           work_item_id
         ]) do
      [[instruction]] when is_binary(instruction) -> instruction
      _ -> ""
    end
  end

  defp config_path(flags, _env) do
    explicit = flags["config"]

    cond do
      is_binary(explicit) and explicit != "" ->
        Path.expand(explicit)

      File.exists?(Path.join(File.cwd!(), "omunculus.toml")) ->
        Path.join(File.cwd!(), "omunculus.toml")

      true ->
        nil
    end
  end

  defp human_granter, do: "human:cli"

  defp open_core(db) do
    {:ok, core} = EventCore.start_link(path: db)
    {:ok, core}
  end

  defp usage(reason) do
    IO.puts(:stderr, Help.usage_error(reason))
    2
  end

  def lookup_request_for_emit(core, request_id) do
    lookup_request_event(core, request_id)
  end

  def fill_grant_defaults(payload, type) when type == "permission.granted" do
    payload
    |> Map.put("granter", payload["granter"] || human_granter())
    |> Map.put("kind", payload["kind"] || "temporary")
  end

  def fill_grant_defaults(payload, _type), do: payload
end

defmodule Omunculus.CLI.Inbox.PolicyPatch do
  @moduledoc false

  @array_re ~r/^(\s*)(\w+)\s*=\s*\[(.*)\]\s*$/

  def grant_tool(path, workspace, tool) do
    header = "[workspaces.#{workspace}]"
    lines = String.split(File.read!(path), "\n", trim: false)

    case split_section(lines, header) do
      :missing ->
        {:error, {:unknown_workspace, workspace}}

      {before, section, rest} ->
        patched = patch_section(section, tool)
        File.write!(path, Enum.join(before ++ patched ++ rest, "\n"))
        :ok
    end
  end

  defp split_section(lines, header) do
    start = Enum.find_index(lines, &(&1 == header))

    if is_nil(start) do
      :missing
    else
      rest = Enum.drop(lines, start + 1)
      stop = Enum.find_index(rest, &section_header?/1) || length(rest)
      section = [header | Enum.take(rest, stop)]
      after_lines = Enum.drop(rest, stop)
      before = Enum.take(lines, start)
      {before, section, after_lines}
    end
  end

  defp section_header?(line), do: String.match?(line, ~r/^\[[^\]]+\]\s*$/)

  defp patch_section(section, tool) do
    {body, state} =
      Enum.map_reduce(section, %{granted: false}, fn line, acc ->
        case Regex.run(@array_re, line) do
          [_, indent, "granted", inner] ->
            {indent <> "granted = " <> format_list(add_tool(parse_list(inner), tool)),
             %{acc | granted: true}}

          [_, indent, "human", inner] ->
            {indent <> "human = " <> format_list(remove_tool(parse_list(inner), tool)), acc}

          [_, indent, "negotiable", inner] ->
            {indent <> "negotiable = " <> format_list(remove_tool(parse_list(inner), tool)), acc}

          _ ->
            {line, acc}
        end
      end)

    if state.granted do
      body
    else
      [Enum.at(body, 0), "granted = [#{inspect(tool)}]"] ++ Enum.drop(body, 1)
    end
  end

  defp parse_list(inner) do
    inner
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn item -> String.trim(item, "\"") end)
  end

  defp format_list(items) do
    "[" <> Enum.map_join(items, ", ", &inspect/1) <> "]"
  end

  defp add_tool(items, tool) do
    if tool in items, do: items, else: Enum.sort(items ++ [tool])
  end

  defp remove_tool(items, tool), do: Enum.reject(items, &(&1 == tool))
end
