defmodule Omunculus.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Omunculus.{CLI, Config, Fixtures, Operations, Project, Server, Store}
  alias Omunculus.Server.{Contract, Socket}

  @access """
  [access]
  creator_role = "participant"
  bootstrap_role = "admin"

  [access.roles.admin]
  scope = "project"
  capabilities = ["project.manage_access", "project.manage_config", "conversation.create", "conversation.read", "conversation.send", "conversation.comment", "conversation.reply", "conversation.manage_access", "conversation.manage"]

  [access.roles.participant]
  scope = "conversation"
  capabilities = ["conversation.read", "conversation.send", "conversation.comment", "conversation.reply", "conversation.manage_access"]

  [access.roles.reader]
  scope = "conversation"
  capabilities = ["conversation.read"]
  """

  test "HTTP authenticates users, scopes conversations and preserves membership" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(project_path, File.read!(project_path) <> "\n" <> @access)

    Fixtures.use_model(dir, fn _assembled, _tools, _call, record, delta, _execution ->
      :ok = delta.("partial")
      :ok = record.("whole")
      {:ok, "whole"}
    end)

    assert {:ok, "access bootstrapped"} =
             CLI.run(
               [
                 "--config",
                 project_path,
                 "access",
                 "bootstrap",
                 "--issuer",
                 "test",
                 "--subject",
                 "admin"
               ],
               dir
             )

    second_dir = Fixtures.tmp_dir()
    Fixtures.install_default(second_dir)
    second_path = Fixtures.config_path(second_dir)
    File.write!(second_path, File.read!(second_path) <> "\n" <> @access)

    assert {:ok, "access bootstrapped"} =
             CLI.run(
               [
                 "--config",
                 second_path,
                 "access",
                 "bootstrap",
                 "--issuer",
                 "test",
                 "--subject",
                 "admin"
               ],
               second_dir
             )

    private_key = JOSE.JWK.generate_key({:rsa, 2048})
    {_fields, public_pem} = JOSE.JWK.to_pem(JOSE.JWK.to_public(private_key))
    public_path = Path.join(dir, "public.pem")
    File.write!(public_path, public_pem)

    port = free_port()
    server_path = Path.join(dir, "server.toml")

    File.write!(server_path, """
    [server]
    host = "127.0.0.1"
    port = #{port}
    max_concurrent = 4
    max_queue = 64
    queue_timeout_ms = 30000
    max_connections = 1

    [auth]
    issuer = "test"
    audience = "omunculus"
    algorithm = "RS256"
    public_key = "public.pem"

    [projects.alpha]
    config = "omunculus.toml"

    [projects.beta]
    config = #{Jason.encode!(second_path)}
    """)

    project = Fixtures.open_project(dir)
    orphan = Fixtures.open_run(project.conn)
    Project.close(project)

    {:ok, _server} = Server.start_link(server_path)
    assert {:error, {:forwarded, ":forbidden"}} = CLI.run(["send", "while server runs"], dir)

    openapi = Req.get!("http://127.0.0.1:#{port}/openapi.json")
    assert openapi.status == 200
    assert ["application/json" <> _] = Req.Response.get_header(openapi, "content-type")
    assert openapi.body["openapi"] == "3.1.0"

    message_operation =
      openapi.body["paths"]["/v1/projects/{project_id}/conversations/{conversation_id}/messages"][
        "post"
      ]

    assert message_operation["operationId"] == "send_message"

    assert Enum.any?(
             message_operation["parameters"],
             &(&1["name"] == "Idempotency-Key" and &1["required"])
           )

    reader = Fixtures.open_project(dir)
    assert {:ok, %{status: "done"}} = Store.view(reader.conn, "run", orphan.id)
    Project.close(reader)

    admin = token(private_key, "admin")
    outsider = token(private_key, "outsider")
    base = "http://127.0.0.1:#{port}/v1/projects/alpha"

    assert Req.get!(base <> "/conversations", headers: auth(outsider)).body["items"] == []
    assert Req.get!(base <> "/conversations", headers: auth("invalid")).status == 401

    assert Req.post!("http://127.0.0.1:#{port}/v1/cli",
             headers: auth(admin),
             json: %{argv: ["send", "x"]}
           ).status ==
             404

    create_headers = auth(admin) ++ [{"idempotency-key", "create-1"}]
    created = Req.post!(base <> "/conversations", headers: create_headers, json: %{})
    assert created.status == 201
    id = created.body["id"]
    assert is_binary(created.body["cursor"])

    repeated_create = Req.post!(base <> "/conversations", headers: create_headers, json: %{})
    assert repeated_create.status == 201
    assert repeated_create.body == created.body

    beta = "http://127.0.0.1:#{port}/v1/projects/beta"
    assert Req.get!(beta <> "/conversations/#{id}", headers: auth(admin)).status == 404

    assert Req.get!(base <> "/conversations/#{id}", headers: auth(outsider)).status == 404

    command_headers = auth(admin) ++ [{"idempotency-key", "message-1"}]
    message_url = base <> "/conversations/#{id}/messages"

    for {key, body} <- [
          {"no-agent", %{message: "hello"}},
          {"agent-and-work", %{message: "hello", agent: "concierge", work_id: "w"}},
          {"empty-agent", %{message: "hello", agent: ""}}
        ] do
      refused =
        Req.post!(message_url, headers: auth(admin) ++ [{"idempotency-key", key}], json: body)

      assert refused.status == 400, key
    end

    not_front =
      Req.post!(message_url,
        headers: auth(admin) ++ [{"idempotency-key", "not-front"}],
        json: %{message: "hello", agent: "worker"}
      )

    assert not_front.status == 422

    first =
      Req.post!(message_url,
        headers: command_headers,
        json: %{message: "hello", agent: "concierge"}
      )

    assert first.status == 202

    repeated =
      Req.post!(message_url,
        headers: command_headers,
        json: %{message: "hello", agent: "concierge"}
      )

    assert repeated.status == 202
    assert repeated.body == first.body

    conflict =
      Req.post!(message_url,
        headers: command_headers,
        json: %{message: "different", agent: "concierge"}
      )

    assert conflict.status == 409

    runs =
      eventually(fn ->
        Req.get!(base <> "/conversations/#{id}/runs", headers: auth(admin)).body["items"]
      end)

    assert Enum.all?(runs, &(&1["origin_issuer"] == "test" and &1["origin_subject"] == "admin"))

    member =
      Req.post!(base <> "/conversations/#{id}/members",
        headers: auth(admin),
        json: %{issuer: "test", subject: "outsider", role: "reader"}
      )

    assert member.status == 200

    events = Req.get!(base <> "/conversations/#{id}/events", headers: auth(outsider))
    assert events.status == 200
    assert Enum.any?(events.body["events"], &(&1["type"] == "conversation"))
    assert Enum.any?(events.body["events"], &(&1["type"] == "prompt"))

    snapshot = Req.get!(base <> "/conversations/#{id}/snapshot", headers: auth(outsider))
    assert snapshot.status == 200
    assert snapshot.body["conversation"]["id"] == id
    assert is_list(snapshot.body["runs"])
    assert is_binary(snapshot.body["cursor"])

    after_snapshot =
      Req.get!(base <> "/conversations/#{id}/events?after=#{snapshot.body["cursor"]}",
        headers: auth(outsider)
      )

    {:ok, snapshot_sequence} = Contract.decode_cursor(snapshot.body["cursor"])

    assert Enum.all?(after_snapshot.body["events"], fn event ->
             Contract.decode_cursor(event["cursor"]) > {:ok, snapshot_sequence}
           end)

    prompt_event = Enum.find(events.body["events"], &(&1["type"] == "prompt"))
    assert prompt_event["actor"] == %{"kind" => "human", "issuer" => "test", "subject" => "admin"}

    resumed =
      Req.get!(
        base <> "/conversations/#{id}/events?after=#{created.body["cursor"]}",
        headers: auth(outsider)
      )

    refute Enum.any?(resumed.body["events"], &(&1["type"] == "conversation"))
    assert Enum.any?(resumed.body["events"], &(&1["type"] == "prompt"))

    denied =
      Req.post!(base <> "/conversations/#{id}/messages",
        headers: auth(outsider) ++ [{"idempotency-key", "denied"}],
        json: %{message: "hello", agent: "concierge"}
      )

    assert denied.status == 404

    for {suffix, body} <- [
          {"", %{question: "Private?"}},
          {"/escalate", %{reason: "Private?", origins: %{q: "hidden"}}}
        ] do
      assert Req.post!(base <> "/conversations/#{id}/requests" <> suffix,
               headers: auth(outsider) ++ [{"idempotency-key", "private-request-#{suffix}"}],
               json: body
             ).status == 404
    end

    upgraded =
      Req.post!(base <> "/conversations/#{id}/members",
        headers: auth(admin),
        json: %{issuer: "test", subject: "outsider", role: "participant"}
      )

    assert upgraded.status == 200

    stream_path = "/v1/projects/alpha/conversations/#{id}/stream"
    revoked = open_stream(port, stream_path, outsider)
    assert_receive {:frame, ^revoked, {:text, _history}}, 3_000

    limited = open_stream(port, stream_path, admin)
    assert_receive {:frame, ^limited, {:close, 1013, "too_many_streams"}}, 3_000

    second_message =
      Req.post!(message_url,
        headers: auth(outsider) ++ [{"idempotency-key", "message-2"}],
        json: %{message: "from another participant", agent: "concierge"}
      )

    assert second_message.status == 202

    updated_events = Req.get!(base <> "/conversations/#{id}/events", headers: auth(admin))

    assert Enum.any?(updated_events.body["events"], fn event ->
             event["type"] == "prompt" and
               event["actor"] ==
                 %{"kind" => "human", "issuer" => "test", "subject" => "outsider"}
           end)

    removed =
      Req.delete!(base <> "/conversations/#{id}/members/test/outsider", headers: auth(admin))

    assert removed.status == 200
    assert_receive {:frame, ^revoked, {:close, 1008, "forbidden"}}, 3_000
    assert Req.get!(base <> "/conversations/#{id}/events", headers: auth(outsider)).status == 404
    assert Req.get!(base <> "/conversations/#{id}/stream", headers: auth(outsider)).status == 404

    plain_log =
      capture_log(fn ->
        plain =
          Req.get!(base <> "/conversations/#{id}/stream", headers: auth(admin), retry: false)

        assert plain.status == 400
      end)

    refute plain_log =~ "HTTPError"

    latest =
      Req.get!(base <> "/conversations/#{id}/snapshot", headers: auth(admin)).body["cursor"]

    stream = open_stream(port, stream_path <> "?after=#{latest}", admin)

    streamed =
      Req.post!(message_url,
        headers: auth(admin) ++ [{"idempotency-key", "message-3"}],
        json: %{message: "streamed", agent: "concierge"}
      )

    assert streamed.status == 202

    {:ok, latest_sequence} = Contract.decode_cursor(latest)

    prompt? = fn event ->
      event["type"] == "prompt" and
        Contract.decode_cursor(event["cursor"]) > {:ok, latest_sequence}
    end

    delta? = &(&1["type"] == "run.delta")

    events =
      receive_events(stream, fn events ->
        Enum.any?(events, prompt?) and Enum.any?(events, delta?)
      end)

    assert %{"text" => "partial", "run_id" => run_id} = Enum.find(events, delta?)
    assert is_binary(run_id)
    refute Map.has_key?(Enum.find(events, delta?), "cursor")

    send(stream, {:send, {:text, "hello"}})
    assert_receive {:frame, ^stream, {:close, 1003, "unsupported"}}, 3_000
  end

  test "each project is served to the local user on a socket next to its store" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(project_path, File.read!(project_path) <> "\n" <> @access)
    uid = Operations.local_principal().subject

    assert {:ok, "access bootstrapped"} =
             CLI.run(
               ["--config", project_path, "access", "bootstrap"] ++
                 ["--issuer", "local", "--subject", uid],
               dir
             )

    local_identity = %{"kind" => "human", "issuer" => "local", "subject" => uid}
    reviewer_identity = %{"kind" => "human", "issuer" => "test", "subject" => "reviewer"}
    final_identity = %{"kind" => "human", "issuer" => "test", "subject" => "final"}
    data = Toml.decode_file!(project_path)

    data =
      put_in(data, ["policy", "request_routes"], [
        %{"from" => local_identity, "via" => [reviewer_identity, final_identity]},
        %{"name" => "origin", "via" => ["origin"]},
        %{"via" => ["parent", "origin"]}
      ])

    File.write!(project_path, Config.Toml.encode(data))

    server_path = Path.join(dir, "server.toml")

    File.write!(server_path, """
    [server]
    max_concurrent = 4
    max_queue = 64
    queue_timeout_ms = 30000
    max_connections = 4

    [projects.solo]
    config = "omunculus.toml"
    """)

    {:ok, config} = Config.load(project_path)
    socket = Socket.path(config.store.path)
    {:ok, server} = Server.start_link(server_path)

    assert Bitwise.band(File.stat!(socket).mode, 0o777) == 0o600
    assert [] = Path.wildcard(Path.join(Path.dirname(socket), ".omunculus-*"), match_dot: true)

    local = fn method, path, opts ->
      Req.request!(
        [method: method, url: "http://localhost" <> path, unix_socket: socket, retry: false] ++
          opts
      )
    end

    assert local.(:get, "/v1/identity", []).body == %{"issuer" => "local", "subject" => uid}

    created =
      local.(:post, "/v1/projects/solo/conversations",
        headers: [{"idempotency-key", "c1"}],
        json: %{}
      )

    assert created.status == 201

    sent =
      local.(:post, "/v1/projects/solo/conversations/#{created.body["id"]}/messages",
        headers: [{"idempotency-key", "m1"}],
        json: %{message: "hi", agent: "concierge"}
      )

    assert sent.status == 202

    conversation_id = created.body["id"]

    [run | _] =
      eventually(fn ->
        local.(:get, "/v1/projects/solo/conversations/#{conversation_id}/runs", []).body["items"]
        |> Enum.filter(&(&1["status"] == "done"))
      end)

    reader = Fixtures.open_project(dir)
    request_id = Fixtures.insert(reader.conn, :requests, %{run_id: run["id"]})
    reply_url = "/v1/projects/solo/conversations/#{conversation_id}/requests/#{request_id}/reply"

    for option <- [nil, "", 12] do
      assert local.(:post, reply_url,
               headers: [{"idempotency-key", "invalid-option-#{inspect(option)}"}],
               json: %{body: "Use blue.", option: option}
             ).status == 400
    end

    reply_headers = [{"idempotency-key", "text-answer"}]
    answered = local.(:post, reply_url, headers: reply_headers, json: %{body: "Use blue."})
    assert answered.status == 202

    assert local.(:post, reply_url, headers: reply_headers, json: %{body: "Use blue."}).body ==
             answered.body

    assert {:ok, %{status: "closed", answer: nil}} =
             Store.view(reader.conn, "request", request_id)

    assert {:ok, [%{body: "Use blue."}]} = Store.comments(reader.conn, :request, request_id)

    assert {:ok, [%{body: reply_body}]} =
             Omunculus.Store.Query.all(
               reader.conn,
               "SELECT body FROM events WHERE type = 'reply' AND request_id = ?",
               [request_id]
             )

    assert Jason.decode!(reply_body) == %{"request_id" => request_id, "body" => "Use blue."}

    eventually(fn ->
      {:ok, runs} = Omunculus.Store.Query.all(reader.conn, "SELECT status FROM runs")
      if length(runs) == 2 and Enum.all?(runs, &(&1.status == "done")), do: runs, else: []
    end)

    assert {:ok, [%{count: runs_before_requests}]} =
             Omunculus.Store.Query.all(reader.conn, "SELECT COUNT(*) AS count FROM runs")

    requests_url = "/v1/projects/solo/conversations/#{conversation_id}/requests"
    headers = [{"idempotency-key", "human-question"}]

    question =
      local.(:post, requests_url, headers: headers, json: %{question: "What is the deadline?"})

    assert question.status == 202

    assert local.(:post, requests_url,
             headers: [{"idempotency-key", "forged-requester"}],
             json: %{
               question: "Spoof?",
               requester: %{kind: "human", issuer: "test", subject: "admin"}
             }
           ).status == 400

    assert local.(:post, requests_url,
             headers: headers,
             json: %{question: "What is the deadline?"}
           ).body == question.body

    assert local.(:post, requests_url, headers: headers, json: %{question: "Changed?"}).status ==
             409

    assert local.(:post, requests_url,
             headers: [{"idempotency-key", "empty-question"}],
             json: %{question: ""}
           ).status == 400

    assert {:ok, [%{id: human_id}]} =
             Omunculus.Store.Query.all(
               reader.conn,
               "SELECT id FROM requests WHERE status = 'pending'"
             )

    assert {:ok, human_request} = Store.view(reader.conn, "request", human_id)
    assert Jason.decode!(human_request.requester) == local_identity
    assert Jason.decode!(human_request.arbiter) == reviewer_identity
    assert is_nil(human_request.run_id)
    assert human_request.reason == "What is the deadline?"

    assert {:ok, ""} =
             CLI.run(
               [
                 "ask",
                 "--conversation_id",
                 conversation_id,
                 "--question",
                 "Pick a date",
                 "--options",
                 ~s(["today","tomorrow"])
               ],
               dir
             )

    assert local.(:post, requests_url <> "/escalate",
             headers: [{"idempotency-key", "not-receiver"}],
             json: %{reason: "Escalate", origins: %{deadline: human_id}}
           ).status == 422

    actor = %{issuer: "test", subject: "reviewer"}

    assert :ok =
             Omunculus.Store.Access.put_member(
               reader,
               Operations.local_principal(),
               actor,
               "participant",
               conversation_id
             )

    assert {:ok, %{ok: true}, origin_events} =
             Operations.call(
               reader,
               "ask",
               %{"conversation_id" => conversation_id, "question" => "Budget?", "to" => "origin"},
               %{principal: actor},
               false
             )

    origin_id = Enum.find(origin_events, &(&1.type == "request")).request_id

    assert {:ok, %{ok: true}, cli_origin_events} =
             Operations.call(
               reader,
               "ask",
               %{"conversation_id" => conversation_id, "question" => "Logo?", "to" => "origin"},
               %{principal: actor},
               false
             )

    cli_origin_id = Enum.find(cli_origin_events, &(&1.type == "request")).request_id

    assert {:ok, ""} =
             CLI.run(
               [
                 "escalate",
                 "--reason",
                 "Which logo?",
                 "--origins",
                 Jason.encode!(%{"logo" => cli_origin_id})
               ],
               dir
             )

    assert {:ok, %{status: "escalated"}} = Store.view(reader.conn, "request", cli_origin_id)
    escalation_headers = [{"idempotency-key", "human-escalation"}]
    escalation_body = %{reason: "Please answer the budget", origins: %{budget: origin_id}}

    escalated =
      local.(:post, requests_url <> "/escalate",
        headers: escalation_headers,
        json: escalation_body
      )

    assert escalated.status == 202

    assert local.(:post, requests_url <> "/escalate",
             headers: escalation_headers,
             json: escalation_body
           ).body == escalated.body

    assert {:ok, %{status: "escalated"}} = Store.view(reader.conn, "request", origin_id)

    assert {:ok, [%{id: top_id}]} =
             Omunculus.Store.Query.all(
               reader.conn,
               "SELECT upstream.id FROM requests upstream JOIN request_escalations link ON link.escalated_id = upstream.id WHERE link.origin_id = ?",
               [origin_id]
             )

    assert {:ok, top} = Store.view(reader.conn, "request", top_id)
    assert is_nil(top.run_id)
    assert top.origins["budget"].id == origin_id
    assert Jason.decode!(top.requester) == local_identity

    assert {:ok, [%{count: run_count}]} =
             Omunculus.Store.Query.all(reader.conn, "SELECT COUNT(*) AS count FROM runs")

    assert run_count == runs_before_requests
    Project.close(reader)

    local_stream =
      open_stream(
        {:local, socket},
        0,
        "/v1/projects/solo/conversations/#{created.body["id"]}/stream",
        [],
        hostname: "localhost"
      )

    assert_receive {:frame, ^local_stream, {:text, _event}}, 3_000

    assert {:ok, _output} = CLI.run(["send", "from the cli"], dir)

    assert [_ | _] =
             runs =
             for(
               %{"id" => id} <- local.(:get, "/v1/projects/solo/conversations", []).body["items"],
               id != created.body["id"],
               run <-
                 local.(:get, "/v1/projects/solo/conversations/#{id}/runs", []).body["items"],
               do: run
             )

    assert Enum.all?(runs, &(&1["status"] == "done"))

    assert {:error, {:forwarded, message}} = CLI.run(["no_such_tool"], dir)
    assert message =~ "no_such_tool"

    :ok = Supervisor.stop(server)
    refute File.exists?(socket)
  end

  defp receive_events(stream, done?, events \\ []) do
    if done?.(events) do
      events
    else
      assert_receive {:frame, ^stream, {:text, json}}, 3_000
      receive_events(stream, done?, events ++ [Jason.decode!(json)])
    end
  end

  defp token(key, subject) do
    claims = %{
      "iss" => "test",
      "aud" => "omunculus",
      "sub" => subject,
      "exp" => System.system_time(:second) + 300
    }

    key
    |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # A WebSocket client process: it sends the test each frame it receives as
  # `{:frame, pid, frame}` and sends the server each `{:send, frame}` it gets.
  defp open_stream(port, path, token),
    do: open_stream("127.0.0.1", port, path, auth(token), [])

  defp open_stream(address, port, path, headers, opts) do
    test = self()

    spawn_link(fn ->
      {:ok, conn} = Mint.HTTP.connect(:http, address, port, [protocols: [:http1]] ++ opts)
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, headers)
      stream_frames(test, conn, ref, nil, nil)
    end)
  end

  # Mint can hand over the first frames before `:done` when they arrive with
  # the upgrade response, so the WebSocket is made as soon as the headers are.
  defp stream_frames(test, conn, ref, websocket, status) do
    receive do
      {:send, frame} ->
        {:ok, websocket, data} = Mint.WebSocket.encode(websocket, frame)
        {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
        stream_frames(test, conn, ref, websocket, status)

      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {conn, websocket, status} =
              Enum.reduce(responses, {conn, websocket, status}, fn
                {:status, ^ref, status}, {conn, nil, _status} ->
                  {conn, nil, status}

                {:headers, ^ref, headers}, {conn, nil, status} ->
                  {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, headers)
                  {conn, websocket, status}

                {:done, ^ref}, acc ->
                  acc

                {:data, ^ref, data}, {conn, websocket, status} ->
                  {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)
                  Enum.each(frames, &send(test, {:frame, self(), &1}))
                  {conn, websocket, status}
              end)

            stream_frames(test, conn, ref, websocket, status)

          {:error, _conn, _reason, _responses} ->
            :closed
        end
    end
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      [] ->
        Process.sleep(25)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  defp eventually(_fun, 0), do: flunk("expected the run to become visible")
end
