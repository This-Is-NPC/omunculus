defmodule Omunculus.Server.Router do
  @moduledoc "The versioned HTTP entry for the Omunculus server."

  use Plug.Router
  use Plug.ErrorHandler
  require Logger

  alias Omunculus.{Errors, Operations}
  alias Omunculus.Server
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

  # Only the local user, who owns the registry file, may add to it.
  OpenAPI.route :post, "/v1/projects", :register_project do
    with {:ok, _project_id} <- Keyword.fetch(conn.assigns.server_opts, :local),
         %{"id" => id, "config" => config} when is_binary(id) and is_binary(config) <-
           conn.body_params do
      case Server.register(Keyword.fetch!(conn.assigns.server_opts, :stream_key), id, config) do
        :ok -> reply(conn, 201, %{id: id})
        {:error, reason} -> command_failed(conn, reason)
      end
    else
      :error -> reply(conn, 404, %{error: "not_found"})
      _invalid -> reply(conn, 400, %{error: "invalid"})
    end
  end

  OpenAPI.route :post, "/v1/call", :local_command do
    with {:ok, project_id} <- Keyword.fetch(conn.assigns.server_opts, :local),
         %{"name" => name} = body when is_binary(name) <- conn.body_params,
         args when is_map(args) <- Map.get(body, "args", %{}) do
      case Project.local_command(project_id, name, args) do
        {:ok, output} -> reply(conn, 200, %{output: output})
        {:error, reason} -> command_failed(conn, reason)
      end
    else
      :error -> reply(conn, 404, %{error: "not_found"})
      _invalid -> reply(conn, 400, %{error: "invalid"})
    end
  end

  OpenAPI.route :post, "/v1/access/bootstrap", :bootstrap_access do
    with {:ok, project_id} <- Keyword.fetch(conn.assigns.server_opts, :local),
         {:ok, target} <- target(conn.body_params) do
      case Project.bootstrap_access(project_id, target) do
        :ok -> reply(conn, 200, %{status: "bootstrapped"})
        {:error, reason} -> command_failed(conn, reason)
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

  OpenAPI.route :get, "/v1/projects/:project_id/works", :list_works do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, state} <- work_state(conn.params["state"]),
         {:ok, works} <- Project.works(project_id, principal, state) do
      reply(conn, 200, %{items: Enum.map(works, &Contract.item(:works, &1))})
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get, "/v1/projects/:project_id/capabilities", :list_capabilities do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, capabilities} <- Project.capabilities(project_id, principal) do
      reply(conn, 200, %{items: capabilities})
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :post, "/v1/projects/:project_id/works/:work_id/revert", :revert_work do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, command_id} <- command_id(conn),
         {:ok, result} <-
           Project.command(
             project_id,
             "revert",
             %{"work_id" => work_id},
             principal,
             nil,
             command_id
           ) do
      reply(conn, 202, Contract.accepted(result))
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get, "/v1/projects/:project_id/stream", :project_stream do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, cursor} <- Contract.decode_cursor(conn.params["after"]),
         :ok <- websocket_request(conn) do
      upgrade_stream(conn, project_id, principal, nil, cursor)
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

  OpenAPI.route :get, "/v1/projects/:project_id/config", :get_config do
    show_config(conn, opts, project_id, Map.take(conn.params, ["whole"]))
  end

  OpenAPI.route :get, "/v1/projects/:project_id/config/:section", :get_config_section do
    show_config(conn, opts, project_id, %{"section" => section})
  end

  OpenAPI.route :get, "/v1/projects/:project_id/config/:section/:name", :get_config_item do
    show_config(conn, opts, project_id, %{"section" => section, "item" => name})
  end

  OpenAPI.route :put, "/v1/projects/:project_id/config/:section", :put_config_table do
    write_config(conn, opts, project_id, {section})
  end

  OpenAPI.route :put, "/v1/projects/:project_id/config/:section/:name", :put_config_item do
    write_config(conn, opts, project_id, {section, name})
  end

  OpenAPI.route :delete, "/v1/projects/:project_id/config/:section", :delete_config_table do
    write_config(conn, opts, project_id, {section})
  end

  OpenAPI.route :delete,
                "/v1/projects/:project_id/config/:section/:name",
                :delete_config_item do
    write_config(conn, opts, project_id, {section, name})
  end

  OpenAPI.route :get, "/v1/projects/:project_id/members", :list_project_members do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, members} <- Project.members(project_id, principal) do
      reply(conn, 200, %{items: Enum.map(members, &Contract.member/1)})
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get, "/v1/projects/:project_id/usage", :get_usage do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, usage} <- Project.usage(project_id, principal, conn.params["conversation"]) do
      reply(conn, 200, usage)
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

  OpenAPI.route :get,
                "/v1/projects/:project_id/conversations/:conversation_id/artifacts",
                :list_artifacts do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, artifacts} <- Project.artifacts(project_id, principal, conversation_id) do
      reply(conn, 200, %{items: Contract.artifacts(artifacts)})
    else
      error -> error_reply(conn, error)
    end
  end

  OpenAPI.route :get,
                "/v1/projects/:project_id/conversations/:conversation_id/artifacts/:name/versions/:version",
                :get_artifact_version do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, number} <- version_number(version),
         {:ok, meta, path} <-
           Project.artifact(project_id, principal, conversation_id, name, number) do
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
         {:ok, files} <- files(Map.get(conn.body_params, "attachments", [])),
         {:ok, attached} <-
           with_attachments(
             conn.body_params |> Map.take(~w(option body parts)),
             files,
             project_id,
             principal,
             conversation_id
           ),
         {:ok, result} <-
           Project.command(
             project_id,
             "reply",
             Map.put(attached, "request_id", request_id),
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
      upgrade_stream(conn, project_id, principal, conversation_id, cursor)
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
        |> Keyword.fetch!(:stream_key)
        |> Server.project_ids()
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn id, {:ok, items} ->
          case Project.socket(id) do
            {:ok, socket} -> {:cont, {:ok, items ++ [%{id: id, socket: socket}]}}
            error -> {:halt, error}
          end
        end)

      :error ->
        opts
        |> Keyword.fetch!(:stream_key)
        |> Server.project_ids()
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
         true <- id in served(opts) do
      {:ok, principal}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp show_config(conn, opts, project_id, args) do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, shown} <- Project.config(project_id, principal, args) do
      reply(conn, 200, shown)
    else
      error -> error_reply(conn, error)
    end
  end

  # A PUT writes `value` to the item; a DELETE removes it. Both name the
  # `revision` read, and a PUT may rename from `from`.
  defp write_config(conn, opts, project_id, item) do
    with {:ok, principal} <- project_principal(conn, opts, project_id),
         {:ok, revision} <- required_string(conn.params, "revision"),
         {:ok, value, from} <- config_value(conn),
         :ok <- Project.edit_config(project_id, principal, revision, item, value, from) do
      reply(conn, 200, %{status: "updated"})
    else
      error -> error_reply(conn, error)
    end
  end

  defp config_value(%{method: "DELETE"}), do: {:ok, nil, nil}

  defp config_value(%{body_params: body}) do
    with [] <- Map.keys(body) -- ~w(revision value from),
         %{} = value <- body["value"],
         {:ok, from} <- optional_string(body, "from") do
      {:ok, value, from}
    else
      _ -> {:error, :invalid}
    end
  end

  # A local socket serves its own project; the TCP listener, every running one.
  defp served(opts),
    do: Keyword.get_lazy(opts, :projects, fn -> Server.project_ids(opts[:stream_key]) end)

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
         [] <- Map.keys(body) -- ~w(message subject agent work_id attachments),
         {:ok, subject} <- subject(body),
         {:ok, files} <- files(Map.get(body, "attachments", [])) do
      case body do
        %{"work_id" => work_id}
        when is_map_key(body, "agent") or not is_binary(work_id) or
               work_id == "" ->
          {:error, :invalid}

        %{"work_id" => work_id} ->
          {:ok, Map.merge(subject, %{"message" => message, "work_id" => work_id}), files}

        _addressed ->
          with {:ok, agent} <- required_string(body, "agent"),
               do: {:ok, Map.merge(subject, %{"message" => message, "agent" => agent}), files}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp send_args(_), do: {:error, :invalid}

  # A message's optional subject: one line of text.
  defp subject(%{"subject" => subject}) when is_binary(subject) do
    if String.trim(subject) != "" and not String.contains?(subject, ["\n", "\r"]),
      do: {:ok, %{"subject" => String.trim(subject)}},
      else: {:error, :invalid}
  end

  defp subject(%{"subject" => _other}), do: {:error, :invalid}
  defp subject(_body), do: {:ok, %{}}

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

  defp work_state(nil), do: {:ok, nil}

  defp work_state(state) do
    if state in Contract.work_states(), do: {:ok, state}, else: {:error, :invalid}
  end

  # A conversation's stream, or with a nil `conversation_id` the project's.
  defp upgrade_stream(conn, project_id, principal, conversation_id, cursor) do
    state = %{
      project: project_id,
      principal: principal,
      conversation_id: conversation_id,
      cursor: cursor,
      readable: [],
      stream_key: conn.assigns.server_opts[:stream_key]
    }

    upgrade_adapter(conn, :websocket, {EventStream, state, []})
  end

  # Bandit validates the rest of the handshake; a plain request stops here
  # so it gets a 400 without Bandit logging a protocol error.
  defp websocket_request(conn) do
    if conn |> get_req_header("upgrade") |> Enum.any?(&(String.downcase(&1) =~ "websocket")),
      do: :ok,
      else: {:error, :invalid}
  end

  defp version_number(text) do
    case Integer.parse(text) do
      {number, ""} when number > 0 -> {:ok, number}
      _invalid -> {:error, :invalid}
    end
  end

  defp error_reply(conn, {:error, :unauthorized}), do: reply(conn, 401, %{error: "unauthorized"})
  defp error_reply(conn, {:error, :invalid}), do: reply(conn, 400, %{error: "invalid"})
  defp error_reply(conn, {:error, :invalid_role}), do: reply(conn, 400, %{error: "invalid_role"})

  defp error_reply(conn, {:error, :command_id_conflict}),
    do: reply(conn, 409, %{error: "command_id_conflict"})

  defp error_reply(conn, {:error, {:config, :stale}}),
    do: reply(conn, 409, %{error: "stale_revision"})

  defp error_reply(conn, {:error, {:config_refused, reason}}),
    do: reply(conn, 422, %{error: "config_refused", message: Errors.format(reason)})

  defp error_reply(conn, {:error, {:not_found, _message}}),
    do: reply(conn, 404, %{error: "not_found"})

  defp error_reply(conn, {:error, :last_administrator}),
    do: reply(conn, 409, %{error: "last_administrator"})

  # A reply to a request that is no longer pending conflicts with its state.
  defp error_reply(conn, {:error, {:reply, reason}}) when reason in [:escalated, :closed],
    do:
      reply(conn, 409, %{
        error: "request_not_pending",
        message: Errors.format({:reply, reason})
      })

  defp error_reply(conn, {:error, {action, _reason}})
       when action in [:request, :escalate, :reply, :grant],
       do: reply(conn, 422, %{error: "request_refused"})

  defp error_reply(conn, {:error, {:attachment, reason}}),
    do: reply(conn, 422, %{error: "attachment_refused", message: inspect(reason)})

  defp error_reply(conn, {:error, {:prompt, _reason}}),
    do: reply(conn, 422, %{error: "message_refused"})

  defp error_reply(conn, {:error, {:tool_failed, message}}),
    do: reply(conn, 422, %{error: "tool_failed", message: message})

  defp error_reply(conn, {:error, reason}) when reason in [:forbidden, :not_found],
    do: reply(conn, 404, %{error: "not_found"})

  defp error_reply(conn, {:error, reason}) do
    Logger.error("server request failed: #{inspect(reason)}")
    reply(conn, 500, %{error: "internal_error"})
  end

  # A request that crashes still answers with the contract's error body.
  @impl Plug.ErrorHandler
  def handle_errors(conn, _failure), do: reply(conn, conn.status, %{error: "internal_error"})

  # A refused command of the local socket: the reason as a sentence.
  defp command_failed(conn, reason),
    do: reply(conn, 422, %{error: "command_failed", message: Errors.format(reason)})

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
