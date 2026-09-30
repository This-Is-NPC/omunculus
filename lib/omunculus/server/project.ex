defmodule Omunculus.Server.Project do
  @moduledoc """
  Owns one project's connection and run cycle for the lifetime of the server.
  """

  use GenServer

  alias Omunculus.{CLI, Config, Cycle, Operations, Project, Run, Store}
  alias Omunculus.Store.Access

  def start_link({id, config_path, global_limits}) do
    GenServer.start_link(__MODULE__, {config_path, global_limits},
      name: {:via, Registry, {Omunculus.Server.Registry, id}}
    )
  end

  def command(id, name, args, principal, conversation_id, command_id) do
    GenServer.call(
      via(id),
      {:command, name, args, principal, conversation_id, command_id},
      :infinity
    )
  end

  def create_conversation(id, principal, command_id),
    do: GenServer.call(via(id), {:create_conversation, principal, command_id})

  def conversations(id, principal), do: GenServer.call(via(id), {:conversations, principal})

  def conversation(id, principal, conversation_id),
    do: GenServer.call(via(id), {:conversation, principal, conversation_id})

  def events(id, principal, conversation_id, cursor),
    do: GenServer.call(via(id), {:events, principal, conversation_id, cursor})

  @doc "Subscribes the calling process to the project's store announcements."
  def subscribe(id), do: Store.subscribe(GenServer.call(via(id), :project).conn)

  @doc """
  Runs a command line in the calling process as one command of the
  project's cycle, returning once the runs it opened have finished.
  """
  def cli(id, argv),
    do: via(id) |> GenServer.call(:project) |> Cycle.command(nil, &CLI.in_project(&1, argv))

  def list(id, principal, conversation_id, kind),
    do: GenServer.call(via(id), {:list, principal, conversation_id, kind})

  def snapshot(id, principal, conversation_id),
    do: GenServer.call(via(id), {:snapshot, principal, conversation_id})

  def put_member(id, actor, target, role, conversation_id),
    do: GenServer.call(via(id), {:put_member, actor, target, role, conversation_id})

  def remove_member(id, actor, target, conversation_id),
    do: GenServer.call(via(id), {:remove_member, actor, target, conversation_id})

  defp via(id), do: {:via, Registry, {Omunculus.Server.Registry, id}}

  @impl true
  def init({config_path, global_limits}) do
    with {:ok, config} <- Config.load(config_path),
         :ok <- require_access(config),
         {:ok, project} <- Project.open(config, lock: true),
         project = %{project | global_limits: global_limits},
         {:ok, cycle} <- Cycle.start_link(project),
         project = %{project | cycle: cycle},
         :ok <- Run.recover(project) do
      {:ok, project}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp require_access(%{access: access}) when is_map(access), do: :ok
  defp require_access(_), do: {:error, :access_required}

  @impl true
  def handle_call({:create_conversation, principal, command_id}, _from, project) do
    {:reply, Access.create_conversation(project, principal, command_id), project}
  end

  def handle_call({:conversations, principal}, _from, project) do
    {:reply, Access.conversations(project, principal), project}
  end

  def handle_call({:conversation, principal, id}, _from, project) do
    {:reply, Access.conversation(project, principal, id), project}
  end

  def handle_call({:events, principal, id, cursor}, _from, project) do
    {:reply, Access.events(project, principal, id, cursor), project}
  end

  def handle_call(:project, _from, project), do: {:reply, project, project}

  def handle_call({:list, principal, id, kind}, _from, project) do
    {:reply, Access.list(project, principal, id, kind), project}
  end

  def handle_call({:snapshot, principal, id}, _from, project) do
    {:reply, Access.snapshot(project, principal, id), project}
  end

  def handle_call({:put_member, actor, target, role, id}, _from, project) do
    {:reply, Access.put_member(project, actor, target, role, id), project}
  end

  def handle_call({:remove_member, actor, target, id}, _from, project) do
    {:reply, Access.remove_member(project, actor, target, id), project}
  end

  def handle_call({:command, name, args, principal, conversation_id, command_id}, _from, project) do
    {:reply, run_command(project, name, args, principal, conversation_id, command_id), project}
  end

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

  defp capability("send"), do: "conversation.send"
  defp capability("reply"), do: "conversation.reply"
  defp capability("comment"), do: "conversation.comment"
  defp capability("inbox_read"), do: "conversation.read"

  defp ensure_target_conversation(project, name, args, conversation_id) do
    target =
      case name do
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
        case Access.conversation_for(project, type, id) do
          {:ok, ^conversation_id} -> :ok
          _ -> {:error, :not_found}
        end
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
      %{"ok" => false} -> {:error, :tool_failed}
    end
  end

  @impl true
  def terminate(_reason, project) do
    GenServer.call(project.cycle, :await, :infinity)
    GenServer.stop(project.cycle)
    Project.close(project)
  end
end
