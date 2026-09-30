defmodule Omunculus.ServerTest do
  use ExUnit.Case, async: false

  alias Omunculus.{CLI, Fixtures, Project, Server, Store}
  alias Omunculus.Server.Contract

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
    assert {:error, :project_in_use} = CLI.run(["send", "while server runs"], dir)

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

    first = Req.post!(message_url, headers: command_headers, json: %{message: "hello"})
    assert first.status == 202

    repeated = Req.post!(message_url, headers: command_headers, json: %{message: "hello"})
    assert repeated.status == 202
    assert repeated.body == first.body

    conflict = Req.post!(message_url, headers: command_headers, json: %{message: "different"})
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
        json: %{message: "hello"}
      )

    assert denied.status == 404

    upgraded =
      Req.post!(base <> "/conversations/#{id}/members",
        headers: auth(admin),
        json: %{issuer: "test", subject: "outsider", role: "participant"}
      )

    assert upgraded.status == 200

    second_message =
      Req.post!(message_url,
        headers: auth(outsider) ++ [{"idempotency-key", "message-2"}],
        json: %{message: "from another participant"}
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
    assert Req.get!(base <> "/conversations/#{id}/events", headers: auth(outsider)).status == 404

    stream = open_stream(port, "/v1/projects/alpha/conversations/#{id}/stream", admin)

    limited = Req.get!(base <> "/conversations/#{id}/stream", headers: auth(admin), retry: false)
    assert limited.status == 429

    :gen_tcp.close(stream)
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

  defp open_stream(port, path, token) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer #{token}\r\n\r\n"
      )

    {:ok, response} = :gen_tcp.recv(socket, 0, 3_000)
    assert response =~ "200 OK"
    socket
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
