defmodule Omunculus.Operations do
  @moduledoc """
  Runs a human command through the same dispatch and follow-up path for
  local callers and the HTTP server.
  """

  alias Omunculus.{Config, Harness}
  alias Omunculus.Store.Access

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

  defp authorize(%{conn: nil}, _name, _args, _actor, _principal),
    do: {:ok, %{capability: nil, conversation_id: nil}}

  defp authorize(project, name, args, actor, principal) do
    with {:ok, config} <- Config.load(project.config_path),
         {:ok, capability, conversation_id} <-
           authorize_configured(project, config, name, args, actor, principal) do
      {:ok, %{capability: capability, conversation_id: conversation_id}}
    end
  end

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
    with {:ok, needed?} <-
           Access.reply_needs_project_config?(project, args["request_id"], args["option"]) do
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
