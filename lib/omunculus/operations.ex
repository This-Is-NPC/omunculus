defmodule Omunculus.Operations do
  @moduledoc """
  Runs a human command through the same dispatch and follow-up path for
  local callers and the HTTP server.
  """

  alias Omunculus.{Config, Harness, Store}
  alias Omunculus.Store.Access
  alias Omunculus.Tools.Record

  @spec call(Omunculus.Project.t(), String.t(), map, map, boolean) ::
          {:ok, map, [map]} | {:error, term}
  def call(project, name, args, actor, follow_up? \\ true) do
    principal = Map.get(actor, :principal, local_principal())

    with {:ok, authorization} <- authorize(project, name, args, actor, principal),
         ctx = %{
           trigger: "cli",
           run_id: nil,
           author: "human",
           agent: nil,
           issuer: principal.issuer,
           subject: principal.subject,
           principal: principal,
           capability: authorization.capability,
           conversation_id: authorization.conversation_id,
           command_id: Map.get(actor, :command_id),
           command_hash: Map.get(actor, :command_hash)
         },
         {:ok, out, events} <- Harness.dispatch(project, name, args, ctx),
         :ok <- maybe_follow_up(follow_up?, project, events) do
      {:ok, out, events}
    end
  end

  @doc """
  Runs the tool `name` as the local principal and follows up its events:
  `{:ok, output}`, or `{:error, {:tool_failed, output}}` when the tool
  refuses.
  """
  @spec command(Omunculus.Project.t(), String.t(), map, boolean) ::
          {:ok, String.t()} | {:error, term}
  def command(project, name, args, follow_up? \\ true) do
    with {:ok, out, _events} <- call(project, name, args, %{}, follow_up?),
         do: output(out)
  end

  @doc """
  `command/4` for a caller that waits for the runs it opened: its output and
  the ids of the events it wrote, which `reply/2` takes once they have
  finished.
  """
  @spec start(Omunculus.Project.t(), String.t(), map) ::
          {:ok, {String.t(), [String.t()]}} | {:error, term}
  def start(project, name, args) do
    with {:ok, out, events} <- call(project, name, args, %{}),
         {:ok, output} <- output(out),
         do: {:ok, {output, Enum.map(events, & &1.id)}}
  end

  @doc """
  The output of a command begun with `start/3`, after the runs it caused
  have finished, followed by what they gave the person: each reply of an
  agent that had no work, each report on a root work and each question
  to an account, in the order they were written, a blank line apart.
  """
  @spec reply(Omunculus.Project.t(), {String.t(), [String.t()]}) :: String.t()
  def reply(project, {output, event_ids}) do
    {:ok, said} = Store.said(project.conn, event_ids)

    [output | Enum.map(said, &told/1)]
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  defp told(%{kind: "reply", text: body}), do: Record.answer(body)
  defp told(%{kind: "report", text: text}), do: text

  defp told(%{kind: "question", request_id: id, text: reason}),
    do: "Question (request #{id}): #{reason}"

  defp output(%{ok: true, output: output}), do: {:ok, output}
  defp output(%{output: output}), do: {:error, {:tool_failed, output}}

  @doc """
  Seeds the first project administrator; only the owner of the project
  config may, and only while the project has no member.
  """
  @spec bootstrap_access(Omunculus.Project.t(), Access.principal()) :: :ok | {:error, term}
  def bootstrap_access(project, target) do
    if File.stat!(project.config_path).uid == File.stat!("/proc/self").uid,
      do: Access.bootstrap(project, target),
      else: {:error, :not_project_owner}
  end

  defp authorize(%{conn: nil}, _name, _args, _actor, _principal),
    do: {:ok, %{capability: nil, conversation_id: nil}}

  defp authorize(project, name, args, actor, principal) do
    with {:ok, config} <- Config.load(project.config_path),
         {:ok, capability, conversation_id} <-
           authorize_configured(project, config, name, args, actor, principal) do
      {:ok, %{capability: capability, conversation_id: conversation_id}}
    end
  end

  defp authorize_configured(project, %{access: nil} = config, name, args, actor, principal)
       when name in ~w(ask escalate),
       do: operation(project, config, name, args, actor, principal)

  defp authorize_configured(_project, %{access: nil}, _name, _args, _actor, _principal),
    do: {:ok, nil, nil}

  defp authorize_configured(project, config, name, args, actor, principal) do
    with {:ok, capability, conversation_id} <-
           operation(project, config, name, args, actor, principal),
         :ok <- Access.check(project.conn, config.access, principal, capability, conversation_id),
         :ok <- check_reply_option(project, config, name, args, principal) do
      {:ok, capability, conversation_id}
    end
  end

  defp operation(project, config, "send", args, actor, principal) do
    case args["work_id"] do
      id when is_binary(id) ->
        with {:ok, conversation_id} <- Access.conversation_for(project, :work, id) do
          {:ok, "conversation.send", conversation_id}
        end

      nil ->
        case Map.get(actor, :conversation_id) do
          id when is_binary(id) ->
            {:ok, "conversation.send", id}

          nil when is_nil(config.access) ->
            {:ok, "conversation.create", nil}

          nil ->
            with {:ok, %{id: id}} <- Access.create_conversation(project, principal) do
              {:ok, "conversation.send", id}
            end
        end
    end
  end

  defp operation(project, _config, "ask", args, actor, principal) do
    id = Map.get(actor, :conversation_id) || args["conversation_id"]

    with true <- is_binary(id) and id != "",
         {:ok, _conversation} <- Access.conversation(project, principal, id) do
      {:ok, "conversation.send", id}
    else
      false -> {:error, :invalid}
      error -> error
    end
  end

  defp operation(project, _config, "escalate", args, _actor, _principal) do
    with {:ok, origins} <- Omunculus.Tools.Args.object(args, "origins"),
         [id | _] <- Map.values(origins) do
      scoped(project, :request, id, "conversation.reply")
    else
      _ -> {:error, :invalid}
    end
  end

  defp operation(project, _config, "reply", args, _actor, _principal),
    do: scoped(project, :request, args["request_id"], "conversation.reply")

  defp operation(project, _config, "inbox_read", args, _actor, _principal),
    do: scoped(project, :inbox, args["inbox_id"], "conversation.read")

  defp operation(project, _config, "comment", args, _actor, _principal) do
    cond do
      is_binary(args["work_id"]) ->
        scoped(project, :work, args["work_id"], "conversation.comment")

      is_binary(args["request_id"]) ->
        scoped(project, :request, args["request_id"], "conversation.comment")

      is_binary(args["inbox_id"]) ->
        scoped(project, :inbox, args["inbox_id"], "conversation.comment")

      true ->
        {:error, :not_found}
    end
  end

  defp operation(project, _config, "changes", %{"work_id" => id}, _actor, _principal),
    do: scoped(project, :work, id, "conversation.read")

  defp operation(project, _config, "revert", %{"work_id" => id}, _actor, _principal),
    do: scoped(project, :work, id, "project.manage_config")

  defp operation(project, _config, "prompt", %{"run" => id}, _actor, _principal),
    do: scoped(project, :run, id, "conversation.read")

  defp operation(_project, _config, _name, _args, _actor, _principal),
    do: {:ok, "project.manage_config", nil}

  defp scoped(project, type, id, capability) when is_binary(id) do
    with {:ok, conversation_id} <- Access.conversation_for(project, type, id) do
      {:ok, capability, conversation_id}
    end
  end

  defp scoped(_project, _type, _id, _capability), do: {:error, :not_found}

  defp check_reply_option(project, config, "reply", args, principal) do
    with {:ok, parts} <- Omunculus.Tools.Args.object(args, "parts"),
         {:ok, needed?} <-
           Access.reply_needs_project_config?(
             project,
             args["request_id"],
             Map.put(args, "parts", parts)
           ) do
      if needed?,
        do: Access.check(project.conn, config.access, principal, "project.manage_config", nil),
        else: :ok
    end
  end

  defp check_reply_option(_project, _config, _name, _args, _principal), do: :ok

  @doc "The operating-system user running this process."
  @spec local_principal() :: Access.principal()
  def local_principal do
    %{issuer: "local", subject: to_string(File.stat!("/proc/self").uid)}
  end

  defp maybe_follow_up(true, project, events), do: Harness.follow_up(project, events)
  defp maybe_follow_up(false, _project, _events), do: :ok
end
