defmodule Omunculus.Server.Router do
  @moduledoc "The versioned HTTP entry for the Omunculus server."

  use Plug.Router
  require Logger

  alias Omunculus.{CLI, Operations}
  alias Omunculus.Server.{Auth, Contract, EventStream, OpenAPI, Project}
  require OpenAPI

  Module.register_attribute(__MODULE__, :openapi_routes, accumulate: true)
  @before_compile OpenAPI

  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  OpenAPI.route :get, "/health", :health do
    conn |> put_resp_content_type("text/plain") |> send_resp(200, "ok")
  end

  OpenAPI.route :get, "/openapi.json", :openapi do
    reply(conn, 200, OpenAPI.document(openapi_routes()))
  end

  OpenAPI.route :get, "/v1/identity", :identity do
    with {:ok, principal} <- authenticate(conn, opts) do
      reply(conn, 200, principal)
    else
      _ -> reply(conn, 401, %{error: "unauthorized"})
    end
  end

  # The local user sees every project of the registry, each with its
  # socket; a user over HTTP, the projects they may read.
  OpenAPI.route :get, "/v1/projects", :list_projects do
    opts = Keyword.merge(opts, conn.assigns.server_opts)

    with {:ok, principal} <- authenticate(conn, opts),
         {:ok, items} <- projects(opts, principal) do
      reply(conn, 200, %{items: items})
    else
      {:error, :unauthorized} -> reply(conn, 401, %{error: "unauthorized"})
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :post, "/v1/cli", :cli do
    with {:ok, project_id} <- Keyword.fetch(conn.assigns.server_opts, :local),
         %{"argv" => [_ | _] = argv} <- conn.body_params,
         true <- Enum.all?(argv, &is_binary/1) do
      case Project.cli(project_id, argv) do
        {:ok, output} ->
          reply(conn, 200, %{output: output})

        {:error, reason} ->
          reply(conn, 422, %{error: "command_failed", message: CLI.format_error(reason)})
      end
    else
      :error -> reply(conn, 404, %{error: "not_found"})
      _invalid -> reply(conn, 400, %{error: "invalid"})
    end
  end

  OpenAPI.route :post, "/v1/projects/:project_id/conversations", :create_conversation do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, command_id} <- command_id(conn),
         {:ok, conversation} <- Project.create_conversation(project_id, principal, command_id) do
      reply(conn, 201, Contract.created(conversation))
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get, "/v1/projects/:project_id/conversations", :list_conversations do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, conversations} <- Project.conversations(project_id, principal) do
      reply(conn, 200, %{items: Enum.map(conversations, &Contract.conversation/1)})
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :post, "/v1/projects/:project_id/members", :put_project_member do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, target} <- target(conn.body_params),
         {:ok, role} <- required_string(conn.body_params, "role"),
         :ok <- Project.put_member(project_id, principal, target, role, nil) do
      reply(conn, 200, %{status: "updated"})
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :delete,
                "/v1/projects/:project_id/members/:issuer/:subject",
                :remove_project_member do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         :ok <-
           Project.remove_member(project_id, principal, %{issuer: issuer, subject: subject}, nil) do
      reply(conn, 200, %{status: "removed"})
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get,
                "/v1/projects/:project_id/conversations/:conversation_id",
                :get_conversation do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, conversation} <- Project.conversation(project_id, principal, conversation_id) do
      reply(conn, 200, Contract.conversation(conversation))
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get,
                "/v1/projects/:project_id/conversations/:conversation_id/snapshot",
                :snapshot do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, snapshot} <- Project.snapshot(project_id, principal, conversation_id) do
      reply(conn, 200, Contract.snapshot(snapshot))
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :post,
                "/v1/projects/:project_id/conversations/:conversation_id/messages",
                :send_message do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, command_id} <- command_id(conn),
         {:ok, args, files} <- send_args(conn.body_params),
         {:ok, args} <- with_attachments(args, files, project_id, principal, conversation_id),
         {:ok, result} <-
           Project.command(
             project_id,
             "send",
             args,
             principal,
             conversation_id,
             command_id
           ) do
      reply(conn, 202, Contract.accepted(result))
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get,
                "/v1/projects/:project_id/conversations/:conversation_id/attachments/:sha256",
                :get_attachment do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, meta, path} <- Project.attachment(project_id, principal, conversation_id, sha256) do
      conn
      |> put_resp_content_type(meta["media_type"], nil)
      |> put_resp_header(
        "content-disposition",
        "attachment; filename*=UTF-8''" <> URI.encode(meta["name"], &URI.char_unreserved?/1)
      )
      |> send_file(200, path)
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get, "/v1/projects/:project_id/agents/:agent/image", :get_agent_image do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, path} <- Project.agent_image(project_id, principal, agent) do
      conn
      |> put_resp_content_type(MIME.from_path(path), nil)
      |> send_file(200, path)
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :post,
                "/v1/projects/:project_id/conversations/:conversation_id/requests",
                :create_request do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, command_id} <- command_id(conn),
         {:ok, _question} <- required_string(conn.body_params, "question"),
         {:ok, _to} <- optional_string(conn.body_params, "to"),
         true <- Map.keys(conn.body_params) -- ~w(question options to) == [],
         true <-
           not Map.has_key?(conn.body_params, "options") or is_list(conn.body_params["options"]),
         {:ok, result} <-
           Project.command(
             project_id,
             "ask",
             conn.body_params,
             principal,
             conversation_id,
             command_id
           ) do
      reply(conn, 202, Contract.accepted(result))
    else
      false -> error_reply(conn, {:error, :invalid})
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :post,
                "/v1/projects/:project_id/conversations/:conversation_id/requests/escalate",
                :escalate_requests do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, command_id} <- command_id(conn),
         {:ok, _reason} <- required_string(conn.body_params, "reason"),
         {:ok, _to} <- optional_string(conn.body_params, "to"),
         true <- Map.keys(conn.body_params) -- ~w(reason origins to) == [],
         true <-
           is_map(conn.body_params["origins"]) and map_size(conn.body_params["origins"]) > 0,
         {:ok, result} <-
           Project.command(
             project_id,
             "escalate",
             conn.body_params,
             principal,
             conversation_id,
             command_id
           ) do
      reply(conn, 202, Contract.accepted(result))
    else
      false -> error_reply(conn, {:error, :invalid})
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :post,
                "/v1/projects/:project_id/conversations/:conversation_id/requests/:request_id/reply",
                :reply_request do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, command_id} <- command_id(conn),
         {:ok, _body} <- required_string(conn.body_params, "body"),
         {:ok, _option} <- optional_string(conn.body_params, "option"),
         {:ok, result} <-
           Project.command(
             project_id,
             "reply",
             conn.body_params
             |> Map.take(~w(option body parts))
             |> Map.put("request_id", request_id),
             principal,
             conversation_id,
             command_id
           ) do
      reply(conn, 202, Contract.accepted(result))
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :post,
                "/v1/projects/:project_id/conversations/:conversation_id/comments",
                :comment do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, command_id} <- command_id(conn),
         {:ok, args} <- comment_args(conn.body_params),
         {:ok, result} <-
           Project.command(
             project_id,
             "comment",
             args,
             principal,
             conversation_id,
             command_id
           ) do
      reply(conn, 202, Contract.accepted(result))
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :post,
                "/v1/projects/:project_id/conversations/:conversation_id/inbox/:inbox_id/read",
                :read_inbox do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, command_id} <- command_id(conn),
         {:ok, result} <-
           Project.command(
             project_id,
             "inbox_read",
             %{"inbox_id" => inbox_id},
             principal,
             conversation_id,
             command_id
           ) do
      reply(conn, 202, Contract.accepted(result))
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get, "/v1/projects/:project_id/conversations/:conversation_id/events", :events do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, cursor} <- Contract.decode_cursor(conn.params["after"]),
         {:ok, events} <- Project.events(project_id, principal, conversation_id, cursor) do
      reply(conn, 200, %{events: Enum.map(events, &Contract.event(project_id, &1))})
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get, "/v1/projects/:project_id/conversations/:conversation_id/stream", :stream do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, cursor} <- Contract.decode_cursor(conn.params["after"]),
         {:ok, _conversation} <- Project.conversation(project_id, principal, conversation_id),
         :ok <- websocket_request(conn) do
      state = %{
        project: project_id,
        principal: principal,
        conversation_id: conversation_id,
        cursor: cursor,
        stream_key: conn.assigns.server_opts[:stream_key]
      }

      upgrade_adapter(conn, :websocket, {EventStream, state, []})
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get,
                "/v1/projects/:project_id/conversations/:conversation_id/:kind",
                :list_items do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, table} <- list_kind(kind),
         {:ok, rows} <- Project.list(project_id, principal, conversation_id, table) do
      reply(conn, 200, %{items: Enum.map(rows, &Contract.item(table, &1))})
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :post,
                "/v1/projects/:project_id/conversations/:conversation_id/members",
                :put_conversation_member do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, target} <- target(conn.body_params),
         {:ok, role} <- required_string(conn.body_params, "role"),
         :ok <- Project.put_member(project_id, principal, target, role, conversation_id) do
      reply(conn, 200, %{status: "updated"})
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :delete,
                "/v1/projects/:project_id/conversations/:conversation_id/members/:issuer/:subject",
                :remove_conversation_member do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         :ok <-
           Project.remove_member(
             project_id,
             principal,
             %{issuer: issuer, subject: subject},
             conversation_id
           ) do
      reply(conn, 200, %{status: "removed"})
    else
      error -> error_reply(conn, error)
    end
  end

  match _ do
    reply(conn, 404, %{error: "not_found"})
  end

  defp authenticate(conn, opts) do
    opts = Keyword.merge(opts, conn.assigns.server_opts)

    case {Keyword.fetch(opts, :local), get_req_header(conn, "authorization")} do
      {{:ok, _project_id}, _header} -> {:ok, Operations.local_principal()}
      {:error, ["Bearer " <> token]} -> Auth.verify(Keyword.fetch!(opts, :auth), token)
      _ -> {:error, :unauthorized}
    end
  end

  defp projects(opts, principal) do
    case Keyword.fetch(opts, :local) do
      {:ok, _id} ->
        opts
        |> Keyword.fetch!(:registry)
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn id, {:ok, items} ->
          case Project.socket(id) do
            {:ok, socket} -> {:cont, {:ok, items ++ [%{id: id, socket: socket}]}}
            error -> {:halt, error}
          end
        end)

      :error ->
        opts
        |> Keyword.fetch!(:projects)
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn id, {:ok, items} ->
          case Project.visible?(id, principal) do
            {:ok, true} -> {:cont, {:ok, items ++ [%{id: id}]}}
            {:ok, false} -> {:cont, {:ok, items}}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp project_principal(conn, opts, id) do
    opts = Keyword.merge(opts, conn.assigns.server_opts)

    with {:ok, principal} <- authenticate(conn, opts),
         true <- id in Keyword.fetch!(opts, :projects) do
      {:ok, principal}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp command_id(conn) do
    case get_req_header(conn, "idempotency-key") do
      [id] when byte_size(id) in 1..128 -> {:ok, id}
      _ -> {:error, :invalid}
    end
  end

  defp required_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid}
    end
  end

  defp required_string(_, _), do: {:error, :invalid}

  defp optional_string(map, key) do
    if Map.has_key?(map, key), do: required_string(map, key), else: {:ok, nil}
  end

  defp target(body) do
    with {:ok, issuer} <- required_string(body, "issuer"),
         {:ok, subject} <- required_string(body, "subject") do
      {:ok, %{issuer: issuer, subject: subject}}
    end
  end

  defp comment_args(body) when is_map(body) do
    targets = Enum.filter(~w(work_id request_id inbox_id), &is_binary(body[&1]))

    with {:ok, text} <- required_string(body, "body"),
         [target] <- targets do
      {:ok, %{"body" => text, target => body[target]}}
    else
      _ -> {:error, :invalid}
    end
  end

  defp comment_args(_), do: {:error, :invalid}

  # A message names the agent of depth 0 it is for, or the work it goes to.
  defp send_args(body) when is_map(body) do
    with {:ok, message} <- required_string(body, "message"),
         [] <- Map.keys(body) -- ~w(message agent work_id attachments),
         {:ok, files} <- files(Map.get(body, "attachments", [])) do
      case body do
        %{"work_id" => work_id}
        when is_map_key(body, "agent") or not is_binary(work_id) or
               work_id == "" ->
          {:error, :invalid}

        %{"work_id" => work_id} ->
          {:ok, %{"message" => message, "work_id" => work_id}, files}

        _addressed ->
          with {:ok, agent} <- required_string(body, "agent"),
               do: {:ok, %{"message" => message, "agent" => agent}, files}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp send_args(_), do: {:error, :invalid}

  # A message's files, each `{name, media_type, data}` with its content in base64.
  defp files(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"name" => name, "media_type" => type, "data" => data} = file, {:ok, files}
      when map_size(file) == 3 and is_binary(name) and is_binary(type) and is_binary(data) ->
        case Base.decode64(data) do
          {:ok, content} -> {:cont, {:ok, files ++ [{name, type, content}]}}
          :error -> {:halt, {:error, :invalid}}
        end

      _file, _acc ->
        {:halt, {:error, :invalid}}
    end)
  end

  defp files(_list), do: {:error, :invalid}

  defp with_attachments(args, [], _project_id, _principal, _conversation_id), do: {:ok, args}

  defp with_attachments(args, files, project_id, principal, conversation_id) do
    with {:ok, kept} <- Project.attach(project_id, principal, conversation_id, files),
         do: {:ok, Map.put(args, "attachments", kept)}
  end

  defp list_kind("works"), do: {:ok, :works}
  defp list_kind("runs"), do: {:ok, :runs}
  defp list_kind("prompts"), do: {:ok, :prompts}
  defp list_kind("requests"), do: {:ok, :requests}
  defp list_kind("inbox"), do: {:ok, :inbox}
  defp list_kind(_), do: {:error, :not_found}

  # Bandit validates the rest of the handshake; a plain request stops here
  # so it gets a 400 without Bandit logging a protocol error.
  defp websocket_request(conn) do
    if conn |> get_req_header("upgrade") |> Enum.any?(&(String.downcase(&1) =~ "websocket")),
      do: :ok,
      else: {:error, :invalid}
  end

  defp error_reply(conn, {:error, :unauthorized}), do: reply(conn, 401, %{error: "unauthorized"})
  defp error_reply(conn, {:error, :invalid}), do: reply(conn, 400, %{error: "invalid"})
  defp error_reply(conn, {:error, :invalid_role}), do: reply(conn, 400, %{error: "invalid_role"})

  defp error_reply(conn, {:error, :command_id_conflict}),
    do: reply(conn, 409, %{error: "command_id_conflict"})

  defp error_reply(conn, {:error, :last_administrator}),
    do: reply(conn, 409, %{error: "last_administrator"})

  defp error_reply(conn, {:error, {action, _reason}}) when action in [:request, :escalate],
    do: reply(conn, 422, %{error: "request_refused"})

  defp error_reply(conn, {:error, {:attachment, reason}}),
    do: reply(conn, 422, %{error: "attachment_refused", message: inspect(reason)})

  defp error_reply(conn, {:error, {:prompt, _reason}}),
    do: reply(conn, 422, %{error: "message_refused"})

  defp error_reply(conn, {:error, :tool_failed}), do: reply(conn, 422, %{error: "tool_failed"})

  defp error_reply(conn, {:error, reason}) when reason in [:forbidden, :not_found],
    do: reply(conn, 404, %{error: "not_found"})

  defp error_reply(conn, {:error, reason}) do
    Logger.error("server request failed: #{inspect(reason)}")
    reply(conn, 500, %{error: "internal_error"})
  end

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
