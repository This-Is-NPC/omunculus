defmodule Omunculus.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Omunculus.{CLI, Config, Fixtures, Operations, Project, Server, Store}
  alias Omunculus.Server.{Contract, Socket}
  alias Omunculus.Store.Access

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

    projects_url = "http://127.0.0.1:#{port}/v1/projects"

    assert Req.get!(projects_url, headers: auth(admin)).body ==
             %{"items" => [%{"id" => "alpha"}, %{"id" => "beta"}]}

    assert Req.get!(projects_url, headers: auth(outsider)).body == %{"items" => []}
    assert Req.get!(projects_url, headers: auth("invalid")).status == 401

    for {path, body} <- [
          {"/v1/call", %{name: "send", args: %{message: "x"}}},
          {"/v1/access/bootstrap", %{issuer: "test", subject: "x"}}
        ] do
      assert Req.post!("http://127.0.0.1:#{port}" <> path, headers: auth(admin), json: body).status ==
               404
    end

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

    assert Req.get!(projects_url, headers: auth(outsider)).body == %{
             "items" => [%{"id" => "alpha"}]
           }

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

  test "a project's works and events reach only whoever may read their conversation" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(project_path, File.read!(project_path) <> "\n" <> @access)
    project = Fixtures.open_project(dir)
    admin = %{issuer: "test", subject: "admin"}
    reader = %{issuer: "test", subject: "reader"}
    :ok = Access.bootstrap(project, admin)
    {:ok, %{id: shared}} = Access.create_conversation(project, admin)
    {:ok, %{id: hidden}} = Access.create_conversation(project, admin)
    :ok = Access.put_member(project, admin, reader, "reader", shared)
    seen = Fixtures.insert(project.conn, :works, %{conversation_id: shared})
    done = Fixtures.insert(project.conn, :works, %{conversation_id: shared, state: "done"})
    unseen = Fixtures.insert(project.conn, :works, %{conversation_id: hidden})

    ids = fn {:ok, rows} -> rows |> Enum.map(& &1.id) |> Enum.sort() end
    assert ids.(Access.works(project, reader, nil)) == Enum.sort([seen, done])
    assert ids.(Access.works(project, reader, "done")) == [done]
    assert ids.(Access.works(project, admin, nil)) == Enum.sort([seen, done, unseen])
    assert {:ok, []} = Access.works(project, %{issuer: "test", subject: "outsider"}, nil)

    assert {:ok, [^shared], events} = Access.project_events(project, reader, 0)
    assert [_ | _] = events
    assert Enum.all?(events, &(&1.conversation_id == shared))
    assert {:ok, readable, all} = Access.project_events(project, admin, 0)
    assert Enum.sort(readable) == Enum.sort([shared, hidden])
    assert Enum.any?(all, &(&1.conversation_id == hidden))
    last = List.last(all).sequence
    assert {:ok, _readable, []} = Access.project_events(project, admin, last)

    Project.close(project)
  end

  test "a project lists its works and streams the events of all its conversations" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(project_path, File.read!(project_path) <> "\n" <> @access)
    project = Fixtures.open_project(dir)
    earlier = Omunculus.Id.new()

    :ok =
      Omunculus.Store.Query.insert(project.conn, :conversations, %{
        id: earlier,
        created_issuer: "local",
        created_subject: "someone",
        created_at: "2026-01-01T00:00:00Z"
      })

    {:ok, _event} =
      Omunculus.Store.Events.append(project.conn, %{
        type: "conversation",
        conversation_id: earlier,
        body: "{}"
      })

    work = Fixtures.insert(project.conn, :works, %{conversation_id: earlier, state: "done"})
    Project.close(project)
    {server, local} = serve_local(dir, project_path)
    {:ok, config} = Config.load(project_path)
    socket = Socket.path(config.store.path)

    [first, second] =
      for key <- ~w(c1 c2) do
        local.(:post, "/v1/projects/solo/conversations",
          headers: [{"idempotency-key", key}],
          json: %{}
        ).body["id"]
      end

    stream =
      open_stream({:local, socket}, 0, "/v1/projects/solo/stream", [], hostname: "localhost")

    created =
      receive_events(stream, &(length(&1) == 3))
      |> Enum.map(&{&1["type"], &1["conversation_id"]})

    assert created == [
             {"conversation", earlier},
             {"conversation", first},
             {"conversation", second}
           ]

    assert [%{"id" => ^work, "conversation_id" => ^earlier, "state" => "done"}] =
             local.(:get, "/v1/projects/solo/works", []).body["items"]

    assert local.(:get, "/v1/projects/solo/works?state=open", []).body == %{"items" => []}
    assert local.(:get, "/v1/projects/solo/works?state=broken", []).status == 400
    assert local.(:get, "/v1/projects/solo/stream", []).status == 400

    :ok = Supervisor.stop(server)
  end

  test "a message carries files, which only its conversation gives back" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(project_path, File.read!(project_path) <> "\n" <> @access)

    data = Toml.decode_file!(project_path)

    data =
      update_in(
        data,
        ["store"],
        &Map.merge(&1, %{"attachments" => "files", "attachment_bytes" => 8})
      )

    File.write!(project_path, Config.Toml.encode(data))

    {server, local} = serve_local(dir, project_path)

    conversation = fn key ->
      local.(:post, "/v1/projects/solo/conversations",
        headers: [{"idempotency-key", key}],
        json: %{}
      ).body["id"]
    end

    id = conversation.("c1")
    other = conversation.("c2")
    messages = "/v1/projects/solo/conversations/#{id}/messages"
    file = %{name: "notes.txt", media_type: "text/plain", data: Base.encode64("hello")}

    send = fn key, attachments ->
      local.(:post, messages,
        headers: [{"idempotency-key", key}],
        json: %{message: "see the notes", agent: "concierge", attachments: attachments}
      )
    end

    assert send.("bad-data", [%{file | data: "not base64!"}]).status == 400
    assert send.("extra-key", [Map.put(file, :size, 5)]).status == 400

    assert %{status: 422, body: %{"error" => "attachment_refused"}} =
             send.("too-large", [%{file | data: Base.encode64("more than eight")}])

    assert send.("m1", [file]).status == 202

    sha256 = :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)

    meta = %{
      "name" => "notes.txt",
      "media_type" => "text/plain",
      "bytes" => 5,
      "sha256" => sha256
    }

    events = local.(:get, "/v1/projects/solo/conversations/#{id}/events", []).body["events"]
    assert %{"body" => %{"attachments" => [^meta]}} = Enum.find(events, &(&1["type"] == "prompt"))

    got = local.(:get, "/v1/projects/solo/conversations/#{id}/attachments/#{sha256}", [])
    assert got.status == 200
    assert got.body == "hello"
    assert ["text/plain" <> _] = Req.Response.get_header(got, "content-type")

    assert Req.Response.get_header(got, "content-disposition") ==
             ["attachment; filename*=UTF-8''notes.txt"]

    assert local.(:get, "/v1/projects/solo/conversations/#{other}/attachments/#{sha256}", []).status ==
             404

    :ok = Supervisor.stop(server)
  end

  test "the operator lists a conversation's artifacts and reads a version of one" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(project_path, File.read!(project_path) <> "\n" <> @access)

    data =
      update_in(
        Toml.decode_file!(project_path),
        ["store"],
        &Map.merge(&1, %{"attachments" => "files", "attachment_bytes" => 64})
      )

    File.write!(project_path, Config.Toml.encode(data))
    {:ok, config} = Config.load(project_path)
    project = Fixtures.open_project(dir)
    conversation = Omunculus.Id.new()
    other = Omunculus.Id.new()

    for id <- [conversation, other] do
      :ok =
        Omunculus.Store.Query.insert(project.conn, :conversations, %{
          id: id,
          created_issuer: "local",
          created_subject: "someone",
          created_at: "2026-01-01T00:00:00Z"
        })
    end

    put = fn id, name, kind, number, content ->
      {:ok, meta} = Omunculus.Artifacts.put(config.store, name, kind, "text/plain", content)
      record = Map.merge(meta, %{"kind" => kind, "version" => number})

      {:ok, _event} =
        Omunculus.Store.Events.append(project.conn, %{
          type: "artifact",
          conversation_id: id,
          body: Jason.encode!(record)
        })
    end

    put.(conversation, "brief", "brief", 1, "first")
    put.(conversation, "brief", "brief", 2, "second")
    put.(other, "secret", "brief", 1, "elsewhere")
    Project.close(project)
    {server, local} = serve_local(dir, project_path)
    base = "/v1/projects/solo/conversations/#{conversation}/artifacts"

    assert %{status: 200, body: %{"items" => [%{"name" => "brief", "kind" => "brief"} = brief]}} =
             local.(:get, base, [])

    assert [%{"version" => 1, "bytes" => 5}, %{"version" => 2, "media_type" => "text/plain"}] =
             brief["versions"]

    got = local.(:get, base <> "/brief/versions/1", [])
    assert got.status == 200
    assert got.body == "first"

    assert Req.Response.get_header(got, "content-disposition") ==
             ["attachment; filename*=UTF-8''brief"]

    assert local.(:get, base <> "/brief/versions/3", []).status == 404
    assert local.(:get, base <> "/secret/versions/1", []).status == 404
    assert local.(:get, base <> "/brief/versions/one", []).status == 400
    assert local.(:post, base, json: %{}).status in [404, 405]

    other_base = "/v1/projects/solo/conversations/#{other}/artifacts"
    assert %{body: %{"items" => [%{"name" => "secret"}]}} = local.(:get, other_base, [])

    :ok = Supervisor.stop(server)
  end

  test "an agent's image is served to whoever sees the project" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(Path.join(dir, "concierge.png"), "png bytes")

    project =
      project_path
      |> File.read!()
      |> String.replace("[agents.concierge]\n", "[agents.concierge]\nimage = \"concierge.png\"\n")

    File.write!(project_path, project <> "\n" <> @access)
    {server, local} = serve_local(dir, project_path)

    got = local.(:get, "/v1/projects/solo/agents/concierge/image", [])
    assert got.status == 200
    assert got.body == "png bytes"
    assert ["image/png" <> _] = Req.Response.get_header(got, "content-type")

    assert local.(:get, "/v1/projects/solo/agents/worker/image", []).status == 404
    assert local.(:get, "/v1/projects/solo/agents/nobody/image", []).status == 404

    :ok = Supervisor.stop(server)
  end

  test "the config is read and edited item by item on the local socket" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(project_path, File.read!(project_path) <> "\n" <> @access)
    {server, local} = serve_local(dir, project_path)
    config = "/v1/projects/solo/config"

    index = local.(:get, config, [])
    assert index.status == 200
    assert index.body["sections"]["models"]["fake"]

    whole = local.(:get, config <> "?whole=true", [])
    assert whole.body["document"]["models"]["fake"]["api"] == "module"
    revision = whole.body["revision"]

    assert local.(:get, config <> "/models", []).body["items"]["fake"]
    item = local.(:get, config <> "/models/fake", [])
    assert %{"item" => "models.fake", "file" => %{"api" => "module"}} = item.body
    assert item.body["revision"] == revision
    assert local.(:get, config <> "/access", []).body["items"]["file"]["roles"]["admin"]
    assert local.(:get, config <> "/policy", []).body["items"]["default_agent"] == "concierge"
    assert local.(:get, config <> "/models/nobody", []).status == 404
    assert local.(:get, config <> "/nothing", []).status == 404

    table = %{"api" => "module", "module" => "Omunculus.Model.Fake"}
    put = local.(:put, config <> "/models/extra", json: %{revision: revision, value: table})
    assert put.status == 200
    assert put.body == %{"status" => "updated"}
    assert local.(:get, config <> "/models/extra", []).body["file"] == table

    stale = local.(:put, config <> "/models/other", json: %{revision: revision, value: table})
    assert stale.status == 409
    assert stale.body == %{"error" => "stale_revision"}
    assert local.(:get, config <> "/models/other", []).status == 404

    revision = local.(:get, config, []).body["revision"]

    refused = local.(:put, config <> "/bogus/x", json: %{revision: revision, value: table})
    assert refused.status == 422
    assert refused.body["error"] == "config_refused"
    assert local.(:get, config, []).body["revision"] == revision

    for body <- [
          %{revision: revision},
          %{revision: revision, value: table, extra: 1},
          %{value: table}
        ] do
      assert local.(:put, config <> "/models/extra", json: body).status == 400
    end

    renamed =
      local.(:put, config <> "/models/renamed",
        json: %{revision: revision, value: table, from: "extra"}
      )

    assert renamed.status == 200
    assert local.(:get, config <> "/models/extra", []).status == 404

    revision = local.(:get, config, []).body["revision"]
    assert local.(:delete, config <> "/models/renamed", []).status == 400
    removed = local.(:delete, config <> "/models/renamed?revision=#{revision}", [])
    assert removed.status == 200
    assert local.(:get, config <> "/models/renamed", []).status == 404

    :ok = Supervisor.stop(server)
  end

  test "members and usage are listed to whoever manages the project" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(project_path, File.read!(project_path) <> "\n" <> @access)

    project = Fixtures.open_project(dir)
    run = Fixtures.open_run(project.conn)

    for usage <- [
          %{prompt_tokens: 10, completion_tokens: 4, cost: 0.5},
          %{input_tokens: 7, cache_read_input_tokens: 3, output_tokens: 2}
        ] do
      {:ok, _event} =
        Omunculus.Store.Events.append(project.conn, %{
          type: "model",
          actor_kind: "agent",
          run_id: run.id,
          body: Jason.encode!(%{usage: usage})
        })
    end

    # A run left open is closed as interrupted when the server opens the project.
    {:ok, _closed} = Omunculus.Store.close_run(project.conn, run.id)
    Project.close(project)
    {server, local} = serve_local(dir, project_path)
    uid = Operations.local_principal().subject
    members = "/v1/projects/solo/members"

    names = fn ->
      Enum.map(local.(:get, members, []).body["items"], &Map.take(&1, ~w(issuer subject role)))
    end

    assert names.() == [%{"issuer" => "local", "subject" => uid, "role" => "admin"}]

    alice = %{issuer: "test", subject: "alice", role: "admin"}
    assert local.(:post, members, json: alice).status == 200
    assert %{"issuer" => "test", "subject" => "alice", "role" => "admin"} in names.()
    assert local.(:delete, members <> "/test/alice", []).status == 200
    assert length(names.()) == 1

    totals = %{"replies" => 2, "input" => 20, "cached" => 3, "output" => 6, "cost" => 0.5}
    usage = local.(:get, "/v1/projects/solo/usage", [])
    assert usage.status == 200

    assert usage.body == %{
             "agents" => [Map.merge(%{"agent" => "concierge", "model" => "fake"}, totals)],
             "total" => totals
           }

    :ok = Supervisor.stop(server)
  end

  test "config, members and usage need the capabilities that manage them" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(project_path, File.read!(project_path) <> "\n" <> @access)

    assert {:ok, "access bootstrapped"} =
             CLI.run(
               ["--config", project_path, "access", "bootstrap"] ++
                 ["--issuer", "test", "--subject", "admin"],
               dir
             )

    private_key = JOSE.JWK.generate_key({:rsa, 2048})
    {_fields, public_pem} = JOSE.JWK.to_pem(JOSE.JWK.to_public(private_key))
    File.write!(Path.join(dir, "public.pem"), public_pem)
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
    """)

    {:ok, server} = Server.start_link(server_path)
    base = "http://127.0.0.1:#{port}/v1/projects/alpha"
    admin = auth(token(private_key, "admin"))
    outsider = auth(token(private_key, "outsider"))

    for path <- ["/config", "/config/models/fake", "/members", "/usage"] do
      assert Req.get!(base <> path, headers: admin).status == 200
      assert Req.get!(base <> path, headers: outsider).status == 404
      assert Req.get!(base <> path, headers: auth("invalid")).status == 401
    end

    revision = Req.get!(base <> "/config", headers: admin).body["revision"]
    table = %{"api" => "module", "module" => "Omunculus.Model.Fake"}
    body = %{revision: revision, value: table}
    assert Req.put!(base <> "/config/models/extra", headers: outsider, json: body).status == 404

    assert Req.delete!(base <> "/config/models/fake?revision=#{revision}", headers: outsider).status ==
             404

    assert Req.get!(base <> "/config/models/extra", headers: admin).status == 404
    assert Req.put!(base <> "/config/models/extra", headers: admin, json: body).status == 200

    :ok = Supervisor.stop(server)
  end

  defmodule HeldHook do
    @moduledoc "A hook that, while a process is registered as `:held_hook`, waits for its `:release`."

    def run(_input) do
      case Process.whereis(:held_hook) do
        nil ->
          :ok

        test ->
          send(test, {:held, self()})
          receive do: (:release -> :ok)
      end

      Omunculus.Tools.Out.ok()
    end
  end

  @tag :capture_log
  test "a command held in its hooks keeps neither reads nor other commands waiting" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(project_path, File.read!(project_path) <> "\n" <> @access)
    hook_dir = Path.join([dir, "tools", "hold-prompt"])
    File.mkdir_p!(hook_dir)

    File.write!(Path.join(hook_dir, "hook.toml"), """
    name = "hold-prompt"
    kind = "hook"
    events = ["prompt"]
    module = "#{inspect(HeldHook)}"
    """)

    {server, local} = serve_local(dir, project_path)
    quick = &local.(&1, &2, [receive_timeout: 2_000] ++ &3)

    created =
      local.(:post, "/v1/projects/solo/conversations",
        headers: [{"idempotency-key", "c1"}],
        json: %{}
      )

    conversation = "/v1/projects/solo/conversations/#{created.body["id"]}"
    Process.register(self(), :held_hook)

    hold = fn ->
      Task.async(fn ->
        local.(:post, conversation <> "/messages",
          headers: [{"idempotency-key", "m1"}],
          json: %{message: "hold", agent: "concierge"}
        )
      end)
    end

    held = hold.()
    assert_receive {:held, hook}, 5_000
    Process.unregister(:held_hook)
    # The same command again, while the first is still held, replays it.
    repeated = hold.()

    assert quick.(:get, conversation <> "/snapshot", []).status == 200
    assert quick.(:get, conversation <> "/events", []).status == 200

    other =
      quick.(:post, "/v1/projects/solo/conversations",
        headers: [{"idempotency-key", "c2"}],
        json: %{}
      )

    assert other.status == 201

    assert quick.(:post, "/v1/projects/solo/conversations/#{other.body["id"]}/messages",
             headers: [{"idempotency-key", "m2"}],
             json: %{message: "go", agent: "concierge"}
           ).status == 202

    send(hook, :release)
    assert %{status: 202, body: body} = Task.await(held)
    assert %{status: 202, body: ^body} = Task.await(repeated)

    # A request the server cannot serve still answers, with the contract's error.
    :ok = Supervisor.terminate_child(server, {:project, "solo"})

    failed =
      quick.(:post, conversation <> "/messages",
        headers: [{"idempotency-key", "m3"}],
        json: %{message: "lost?", agent: "concierge"}
      )

    assert {failed.status, failed.body} == {500, %{"error" => "internal_error"}}

    :ok = Supervisor.stop(server)
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

    assert local.(:get, "/v1/projects", []).body ==
             %{"items" => [%{"id" => "solo", "socket" => socket}]}

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

    assert {:error, reason} = CLI.run(["no_such_tool"], dir)
    assert CLI.message(reason) =~ "no_such_tool"

    assert %{status: 200, body: %{"output" => output}} =
             local.(:post, "/v1/call", json: %{name: "runs", args: %{}})

    assert output =~ "runs, newest first"

    assert local.(:post, "/v1/call", json: %{name: "no_such_tool"}).body["message"] =~
             "no_such_tool"

    assert local.(:post, "/v1/call", json: %{argv: ["runs"]}).status == 400
    assert local.(:post, "/v1/call", json: %{name: "runs", args: ["x"]}).status == 400

    assert {:error, {:forwarded, _members_exist}} =
             CLI.run(["access", "bootstrap", "--issuer", "test", "--subject", "late"], dir)

    assert local.(:post, "/v1/access/bootstrap", json: %{issuer: "test"}).status == 400

    :ok = Supervisor.stop(server)
    refute File.exists?(socket)
  end

  test "the local socket registers a project into the running server and its registry" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    project_path = Fixtures.config_path(dir)
    File.write!(project_path, File.read!(project_path) <> "\n" <> @access)
    {server, local} = serve_local(dir, project_path)

    second_dir = Fixtures.tmp_dir()
    Fixtures.install_default(second_dir)
    second_path = Fixtures.config_path(second_dir)
    File.write!(second_path, File.read!(second_path) <> "\n" <> @access)

    bare_dir = Fixtures.tmp_dir()
    Fixtures.install_default(bare_dir)

    uid = Operations.local_principal().subject

    assert {:ok, "access bootstrapped"} =
             CLI.run(
               ["--config", second_path, "access", "bootstrap"] ++
                 ["--issuer", "local", "--subject", uid],
               second_dir
             )

    registry = Path.join(dir, "server.toml")

    register = fn id, config -> local.(:post, "/v1/projects", json: %{id: id, config: config}) end

    assert %{status: 201, body: %{"id" => "second"}} = register.("second", second_path)

    # Refused: a used id, a config without [access], a missing file, no config.
    assert register.("second", second_path).status == 422
    assert register.("solo", second_path).status == 422
    assert register.("bare", Fixtures.config_path(bare_dir)).status == 422
    assert register.("gone", Path.join(dir, "missing.toml")).status == 422
    assert local.(:post, "/v1/projects", json: %{id: "x"}).status == 400

    # The registry keeps its other entries and reads again as a server's.
    {:ok, registered} = Server.Config.load(registry)
    assert registered.projects == %{"solo" => project_path, "second" => second_path}
    assert registered.limits.max_concurrent == 4

    # Both projects are listed and the new one answers on its own socket.
    assert %{status: 200, body: %{"items" => items}} = local.(:get, "/v1/projects", [])
    assert Enum.map(items, & &1["id"]) == ["second", "solo"]
    second_socket = Enum.find(items, &(&1["id"] == "second"))["socket"]

    assert %{status: 200} =
             Req.request!(
               method: :get,
               url: "http://localhost/v1/projects/second/conversations",
               unix_socket: second_socket,
               retry: false
             )

    assert local.(:get, "/v1/projects/solo/conversations", []).status == 200

    :ok = Supervisor.stop(server)
  end

  # Bootstraps the local administrator of the project at `project_path`, serves
  # it alone as "solo", and gives a request on its local socket.
  defp serve_local(dir, project_path) do
    uid = Operations.local_principal().subject

    assert {:ok, "access bootstrapped"} =
             CLI.run(
               ["--config", project_path, "access", "bootstrap"] ++
                 ["--issuer", "local", "--subject", uid],
               dir
             )

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

    local = fn method, path, opts ->
      Req.request!(
        [method: method, url: "http://localhost" <> path, unix_socket: socket, retry: false] ++
          opts
      )
    end

    {server, local}
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
