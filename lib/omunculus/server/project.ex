defmodule Omunculus.Server.Project do
  @moduledoc """
  Owns one project's connection and run cycle for the lifetime of the server.
  The process only opens and closes them: it keeps the project as its
  registry value, and every read and command runs in the process that asks
  for it, so none waits behind another but on the store connection itself.
  """

  use GenServer

  alias Omunculus.{Artifacts, Attachments, Config, Cycle, Operations, Project, Run, Store}
  alias Omunculus.Store.Access

  def start_link({id, config_path, global_limits}) do
    GenServer.start_link(__MODULE__, {id, config_path, global_limits}, name: via(id))
  end

  @doc """
  Runs a command in the calling process. Commands with the same
  `command_id` of one principal run one after another, so a repeated one
  replays the receipt the first left.
  """
  def command(id, name, args, principal, conversation_id, command_id) do
    project = project(id)

    :global.trans({{__MODULE__, id, principal, command_id}, self()}, fn ->
      run_command(project, name, args, principal, conversation_id, command_id)
    end)
  end

  def create_conversation(id, principal, command_id),
    do: Access.create_conversation(project(id), principal, command_id)

  def conversations(id, principal), do: Access.conversations(project(id), principal)

  @doc "Whether `principal` sees the project."
  def visible?(id, principal), do: Access.visible?(project(id), principal)

  @doc "The project's local socket."
  def socket(id) do
    with {:ok, config} <- Config.load(project(id).config_path),
         do: {:ok, Omunculus.Server.Socket.path(config.store.path)}
  end

  def conversation(id, principal, conversation_id),
    do: Access.conversation(project(id), principal, conversation_id)

  def events(id, principal, conversation_id, cursor),
    do: Access.events(project(id), principal, conversation_id, cursor)

  @doc "The events after `cursor` of every conversation `principal` may read, with their ids."
  def project_events(id, principal, cursor),
    do: Access.project_events(project(id), principal, cursor)

  @doc "The capabilities `principal`'s project role grants."
  def capabilities(id, principal), do: Access.capabilities(project(id), principal)

  @doc "The works of every conversation `principal` may read, those in `state` alone when given."
  def works(id, principal, state), do: Access.works(project(id), principal, state)

  @doc """
  Keeps the files of a message `principal` may send to `conversation_id`,
  each `{name, media_type, content}`, and gives what describes each.
  """
  def attach(id, principal, conversation_id, files) do
    project = project(id)

    with :ok <- Access.check(project, principal, "conversation.send", conversation_id),
         {:ok, config} <- Config.load(project.config_path) do
      Enum.reduce_while(files, {:ok, []}, fn {name, media_type, content}, {:ok, kept} ->
        case Attachments.put(config.store, name, media_type, content) do
          {:ok, meta} -> {:cont, {:ok, kept ++ [meta]}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc "The attachment of `sha256` in `conversation_id`, with the file kept for it."
  def attachment(id, principal, conversation_id, sha256) do
    project = project(id)

    with :ok <- Access.check(project, principal, "conversation.read", conversation_id),
         {:ok, attached} <- Store.attachments(project.conn, conversation_id),
         %{} = meta <- Enum.find(attached, &(&1["sha256"] == sha256)) || {:error, :not_found},
         {:ok, config} <- Config.load(project.config_path),
         {:ok, path} <- Attachments.path(config.store, sha256) do
      {:ok, meta, path}
    end
  end

  @doc "The artifact versions of `conversation_id`, for a principal who may read it."
  def artifacts(id, principal, conversation_id) do
    project = project(id)

    with :ok <- Access.check(project, principal, "conversation.read", conversation_id),
         do: Store.artifacts(project.conn, conversation_id)
  end

  @doc "The version `number` of artifact `name` in `conversation_id`, with the file kept for it."
  def artifact(id, principal, conversation_id, name, number) do
    with {:ok, versions} <- artifacts(id, principal, conversation_id),
         %{} = meta <- Artifacts.find(versions, name, number) || {:error, :not_found},
         {:ok, config} <- Config.load(project(id).config_path),
         {:ok, path} <- Attachments.path(config.store, meta["sha256"]) do
      {:ok, meta, path}
    end
  end

  @doc "The file of an agent's image, for a principal who sees the project."
  def agent_image(id, principal, agent) do
    project = project(id)

    with {:ok, true} <- Access.visible?(project, principal),
         {:ok, config} <- Config.load(project.config_path),
         %{image: path} when is_binary(path) <- Map.get(config.agents, agent) do
      {:ok, path}
    else
      {:ok, false} -> {:error, :not_found}
      {:error, _reason} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc "Subscribes the calling process to the project's store announcements."
  def subscribe(id), do: Store.subscribe(project(id).conn)

  @doc """
  Runs the tool `name` as the local principal in the calling process, as
  one command of the project's cycle, returning once the runs it opened
  have finished.
  """
  def local_command(id, name, args),
    do: Cycle.command(project(id), nil, &Operations.command(&1, name, args))

  @doc "Seeds the first project administrator, for the owner of the project config."
  def bootstrap_access(id, target), do: Operations.bootstrap_access(project(id), target)

  def list(id, principal, conversation_id, kind),
    do: Access.list(project(id), principal, conversation_id, kind)

  def snapshot(id, principal, conversation_id),
    do: Access.snapshot(project(id), principal, conversation_id)

  def put_member(id, actor, target, role, conversation_id),
    do: Access.put_member(project(id), actor, target, role, conversation_id)

  def remove_member(id, actor, target, conversation_id),
    do: Access.remove_member(project(id), actor, target, conversation_id)

  def members(id, principal), do: Access.members(project(id), principal)

  @doc "The usage of the project's recorded model replies, per agent with its configured model."
  def usage(id, principal) do
    project = project(id)

    with {:ok, per_agent} <- Access.usage(project, principal),
         {:ok, config} <- Config.load(project.config_path) do
      {:ok,
       Omunculus.Server.Contract.usage(
         per_agent,
         Map.new(config.agents, fn {name, agent} -> {name, agent.model} end)
       )}
    end
  end

  @doc "What the `config` tool shows for `args`, for a principal who manages the project's config."
  def config(id, principal, args) do
    project = project(id)

    with :ok <- Access.check(project, principal, "project.manage_config"),
         do: Omunculus.Tools.Config.show(project.config_path, args)
  end

  @doc "Writes or, for a nil `value`, removes one config item as `Config.edit/5` does."
  def edit_config(id, principal, revision, item, value, from) do
    project = project(id)

    with :ok <- Access.check(project, principal, "project.manage_config") do
      case Config.edit(project.config_path, revision, item, value, from) do
        :ok -> :ok
        {:error, {:config, :stale}} = stale -> stale
        {:error, reason} -> {:error, {:config_refused, reason}}
      end
    end
  end

  defp via(id), do: {:via, Registry, {Omunculus.Server.Registry, id}}

  # The project the process opened, which it keeps as its registry value.
  defp project(id) do
    [{_pid, %Project{} = project}] = Registry.lookup(Omunculus.Server.Registry, id)
    project
  end

  @impl true
  def init({id, config_path, global_limits}) do
    with {:ok, config} <- Config.load(config_path),
         :ok <- require_access(config),
         {:ok, project} <- Project.open(config, lock: true),
         project = %{project | global_limits: global_limits},
         {:ok, cycle} <- Cycle.start_link(project),
         project = %{project | cycle: cycle},
         :ok <- Run.recover(project) do
      {_project, _nil} = Registry.update_value(Omunculus.Server.Registry, id, fn _ -> project end)
      {:ok, project}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp require_access(%{access: access}) when is_map(access), do: :ok
  defp require_access(_), do: {:error, :access_required}

  defp run_command(project, name, args, principal, conversation_id, command_id) do
    hash =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({name, args, conversation_id}, [:deterministic])
      )
      |> Base.encode16(case: :lower)

    with :ok <- Access.check(project, principal, capability(name), conversation_id),
         :ok <- ensure_target_conversation(project, name, args, conversation_id),
         {:ok, receipt} <- Access.receipt(project, principal, command_id),
         {:ok, result} <-
           dispatch_or_replay(
             project,
             name,
             args,
             principal,
             conversation_id,
             command_id,
             hash,
             receipt
           ) do
      {:ok, result}
    end
  end

  defp capability("ask"), do: "conversation.send"
  defp capability("escalate"), do: "conversation.reply"
  defp capability("send"), do: "conversation.send"
  defp capability("reply"), do: "conversation.reply"
  defp capability("comment"), do: "conversation.comment"
  defp capability("inbox_read"), do: "conversation.read"
  defp capability("revert"), do: "project.manage_config"

  defp ensure_target_conversation(_project, "revert", _args, _conversation_id), do: :ok

  defp ensure_target_conversation(project, "escalate", args, conversation_id) do
    with {:ok, origins} <- Omunculus.Tools.Args.object(args, "origins") do
      Enum.reduce_while(Map.values(origins), :ok, fn id, :ok ->
        case target_conversation(project, :request, id, conversation_id) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp ensure_target_conversation(project, name, args, conversation_id) do
    target =
      case name do
        "ask" ->
          nil

        "send" ->
          if(args["work_id"], do: {:work, args["work_id"]})

        "reply" ->
          {:request, args["request_id"]}

        "comment" ->
          cond do
            args["work_id"] -> {:work, args["work_id"]}
            args["request_id"] -> {:request, args["request_id"]}
            args["inbox_id"] -> {:inbox, args["inbox_id"]}
          end

        "inbox_read" ->
          {:inbox, args["inbox_id"]}
      end

    case target do
      nil ->
        :ok

      {type, id} ->
        target_conversation(project, type, id, conversation_id)
    end
  end

  defp target_conversation(project, type, id, conversation_id) do
    case Access.conversation_for(project, type, id) do
      {:ok, ^conversation_id} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp dispatch_or_replay(
         _project,
         _name,
         _args,
         _principal,
         _conversation_id,
         _command_id,
         hash,
         %{operation: hash} = receipt
       ),
       do: receipt_result(receipt)

  defp dispatch_or_replay(
         _project,
         _name,
         _args,
         _principal,
         _conversation_id,
         _command_id,
         _hash,
         %{}
       ),
       do: {:error, :command_id_conflict}

  defp dispatch_or_replay(project, name, args, principal, conversation_id, command_id, hash, nil) do
    actor = %{
      principal: principal,
      conversation_id: conversation_id,
      command_id: command_id,
      command_hash: hash
    }

    with {:ok, _out, _events} <- Operations.call(project, name, args, actor),
         {:ok, receipt} <- Access.receipt(project, principal, command_id) do
      case receipt do
        nil -> {:error, :missing_command_receipt}
        receipt -> receipt_result(receipt)
      end
    else
      error -> error
    end
  end

  defp receipt_result(%{result: result}) do
    case Jason.decode!(result) do
      %{"ok" => true} = response -> {:ok, Map.delete(response, "ok")}
      %{"ok" => false, "message" => message} -> {:error, {:tool_failed, message}}
    end
  end

  @impl true
  def terminate(_reason, project) do
    GenServer.call(project.cycle, :await, :infinity)
    GenServer.stop(project.cycle)
    Project.close(project)
  end
end
