defmodule Omunculus.Tools.S3SyncTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Omunculus.{Artifacts, Config, Fixtures, Run}
  alias Omunculus.Store.Query
  alias Omunculus.Tools.{PullArtifacts, PushArtifacts}

  # An in-memory S3 endpoint, path style: objects and a request log.
  defmodule Stub do
    @behaviour Plug

    def init(agent), do: agent

    def call(conn, agent) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      ["", "bucket" | rest] = String.split(conn.request_path, "/")
      key = rest |> Enum.join("/") |> URI.decode()
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      [digest] = Plug.Conn.get_req_header(conn, "x-amz-content-sha256")

      signed =
        String.starts_with?(authorization, "AWS4-HMAC-SHA256 Credential=AKID/") and
          String.contains?(authorization, "/eu-west-1/s3/aws4_request") and
          digest == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      Agent.update(
        agent,
        &Map.update!(&1, :log, fn log -> [{conn.method, key, signed} | log] end)
      )

      respond(conn, agent, conn.method, key, body)
    end

    defp respond(conn, agent, "PUT", key, body) do
      Agent.update(agent, &put_in(&1, [:objects, key], body))
      send_resp(conn, 200, "")
    end

    defp respond(conn, agent, "HEAD", key, _body) do
      status = if Map.has_key?(Agent.get(agent, & &1.objects), key), do: 200, else: 404
      send_resp(conn, status, "")
    end

    defp respond(conn, agent, "GET", "", _body) do
      conn = fetch_query_params(conn)
      prefix = conn.query_params["prefix"]
      after_token = conn.query_params["continuation-token"] || ""

      keys =
        agent
        |> Agent.get(&Map.keys(&1.objects))
        |> Enum.filter(&(String.starts_with?(&1, prefix) and &1 > after_token))
        |> Enum.sort()

      {page, rest} = Enum.split(keys, 2)

      token =
        if rest == [],
          do: "",
          else: "<NextContinuationToken>#{List.last(page)}</NextContinuationToken>"

      contents = Enum.map_join(page, &"<Contents><Key>#{&1}</Key></Contents>")
      send_resp(conn, 200, "<ListBucketResult>#{contents}#{token}</ListBucketResult>")
    end

    defp respond(conn, agent, "GET", key, _body) do
      case Agent.get(agent, & &1.objects[key]) do
        nil -> send_resp(conn, 404, "")
        body -> send_resp(conn, 200, body)
      end
    end
  end

  defp toml(s3) do
    """
    [agents.concierge]
    depth = 0
    text = "c"

    [store]
    path = "s.sqlite3"
    attachments = "files"
    attachment_bytes = 256

    [auth]
    store = "auth.json"

    [auth.s3_id]
    kind = "api_key"
    key = "AKID"

    [auth.s3_secret]
    kind = "api_key"
    key = "!printf shh"

    #{s3}
    """
  end

  defp s3(port, overrides) do
    keys =
      Keyword.merge(
        [
          bucket: ~s("bucket"),
          endpoint: ~s("http://127.0.0.1:#{port}"),
          region: ~s("eu-west-1"),
          prefix: ~s("team 1/"),
          path_style: "true",
          credentials: ~s({ access_key_id = "s3_id", secret_access_key = "s3_secret" })
        ],
        overrides
      )

    "[s3]\n" <> Enum.map_join(keys, "\n", fn {key, value} -> "#{key} = #{value}" end)
  end

  defp load(port, overrides) do
    dir = Fixtures.tmp_dir()
    Fixtures.write_config(dir, toml(s3(port, overrides)))
    {Config.load(Fixtures.config_path(dir)), Fixtures.config_path(dir)}
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> %{objects: %{}, log: []} end)

    {:ok, server} =
      Bandit.start_link(plug: {Stub, agent}, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {{:ok, config}, config_path} = load(port, [])
    %{agent: agent, server: server, port: port, config_path: config_path, store: config.store}
  end

  defp version(ctx, number, content) do
    {:ok, meta} = Artifacts.put(ctx.store, "brief", "brief", "text/plain", content)
    Map.merge(meta, %{"kind" => "brief", "version" => number, "by" => "seller", "at" => "now"})
  end

  defp call(tool, ctx, args, versions, conversation \\ "c1") do
    tool.run(%{
      args: args,
      view: %{"artifacts" => versions, "run" => [%{conversation_id: conversation}]},
      config_path: ctx.config_path
    })
  end

  test "push uploads each content and record once, signed, and repeats safely", ctx do
    versions = [version(ctx, 1, "first"), version(ctx, 2, "second")]

    assert %{"ok" => true, "output" => "pushed 4 objects, 0 already in the bucket"} =
             call(PushArtifacts, ctx, %{}, versions)

    %{objects: objects, log: log} = Agent.get(ctx.agent, & &1)
    sha = hd(versions)["sha256"]
    assert objects["team 1/objects/#{sha}"] == "first"

    assert %{"version" => 2, "sha256" => _} =
             Jason.decode!(objects["team 1/conversations/c1/brief/2.json"])

    assert Enum.all?(log, fn {_method, _key, signed} -> signed end)

    puts = fn -> Enum.count(Agent.get(ctx.agent, & &1.log), &match?({"PUT", _, _}, &1)) end
    assert puts.() == 4

    assert %{"ok" => true, "output" => "pushed 0 objects, 4 already in the bucket"} =
             call(PushArtifacts, ctx, %{}, versions)

    assert puts.() == 4
  end

  test "pull restores the versions a conversation lacks, once", ctx do
    versions = [version(ctx, 1, "first"), version(ctx, 2, "second")]
    call(PushArtifacts, ctx, %{}, versions)

    assert %{"ok" => true, "output" => "restored 2 versions", "emit" => [one, two]} =
             call(PullArtifacts, ctx, %{"conversation" => "c1"}, [], "c2")

    assert %{"type" => "artifact", "body" => %{"content" => "first", "base" => 0}} = one
    assert %{"body" => %{"content" => "second", "base" => 1, "name" => "brief"}} = two

    assert %{"emit" => [%{"body" => %{"content" => "second"}}]} =
             call(PullArtifacts, ctx, %{"conversation" => "c1"}, [hd(versions)], "c2")

    assert %{"output" => "restored 0 versions", "emit" => []} =
             call(PullArtifacts, ctx, %{"conversation" => "c1"}, versions, "c2")
  end

  test "pull restores a version of bytes as the same bytes", ctx do
    {:ok, meta} = Artifacts.put(ctx.store, "blob", "brief", "image/png", <<255, 254>>)
    blob = Map.merge(meta, %{"kind" => "brief", "version" => 1, "by" => "seller", "at" => "now"})
    call(PushArtifacts, ctx, %{}, [blob])

    assert %{"output" => "restored 1 versions", "emit" => [%{"body" => body}]} =
             call(PullArtifacts, ctx, %{}, [], "c1")

    assert body["base64"] == Base.encode64(<<255, 254>>)
    refute Map.has_key?(body, "content")
    assert {:ok, <<255, 254>>} = Artifacts.content(body)
  end

  test "pull names a version that does not follow the held ones", ctx do
    call(PushArtifacts, ctx, %{}, [version(ctx, 2, "second")])

    assert %{"output" => "restored 0 versions; left out, out of order: brief v2"} =
             call(PullArtifacts, ctx, %{}, [], "c1")
  end

  test "a bucket that refuses fails the call in words", ctx do
    Supervisor.stop(ctx.server)

    assert %{"ok" => false, "output" => output} =
             call(PushArtifacts, ctx, %{}, [version(ctx, 1, "x")])

    assert output =~ "bucket"
  end

  test "a hook on artifact pushes each version a run writes", ctx do
    dir = Fixtures.tmp_dir()

    Fixtures.write_config(
      dir,
      String.replace(
        toml(s3(ctx.port, [])),
        "[agents.concierge]\ndepth = 0\ntext = \"c\"",
        "[agents.concierge]\ndepth = 0\ntext = \"c\"\ntools = [\"put_artifact\", \"push_artifacts\"]"
      )
    )

    hook = Path.join([dir, "tools", "on-artifact"])
    File.mkdir_p!(hook)

    File.write!(Path.join(hook, "hook.toml"), """
    name = "on-artifact"
    kind = "hook"
    events = ["artifact"]
    module = "Omunculus.Hooks.Noop"
    chains = ["push_artifacts"]
    then = ["push_artifacts"]
    """)

    project = Fixtures.open_project(dir)
    conversation_id = Omunculus.Id.new()

    :ok =
      Query.insert(project.conn, :conversations, %{
        id: conversation_id,
        created_at: "2026-01-01T00:00:00Z",
        created_issuer: "local",
        created_subject: Omunculus.Operations.local_principal().subject
      })

    message_id =
      Fixtures.insert(project.conn, :prompts, %{
        kind: "message",
        body: "hi",
        conversation_id: conversation_id
      })

    Fixtures.use_model(project, fn _assembled, _tools, call ->
      {:ok, _} =
        call.("put_artifact", %{
          "name" => "b",
          "kind" => "brief",
          "content" => "v1",
          "media_type" => "text/plain"
        })

      {:ok, "done"}
    end)

    assert {:ok, _run} = Run.open(project, Fixtures.opening(message_id))
    objects = Agent.get(ctx.agent, & &1.objects)
    assert objects["team 1/conversations/#{conversation_id}/b/1.json"]
    assert "v1" in Map.values(objects)
    Omunculus.Project.close(project)
  end

  describe "the [s3] table" do
    test "names a provider [auth] has, and no secret", ctx do
      bad = ~s({ access_key_id = "s3_id", secret_access_key = "nope" })
      assert {{:error, {:s3, {:unknown_provider, "nope"}}}, _} = load(ctx.port, credentials: bad)

      assert {{:error, {:s3, {:invalid, :credentials}}}, _} =
               load(ctx.port, credentials: ~s({ access_key_id = "s3_id" }))

      assert {{:error, {:s3, {:invalid, :endpoint}}}, _} = load(ctx.port, endpoint: ~s("ftp://x"))
      assert {{:error, {:s3, {:invalid, :path_style}}}, _} = load(ctx.port, path_style: ~s("yes"))
    end

    test "refuses a call without the table" do
      dir = Fixtures.tmp_dir()
      Fixtures.write_config(dir, toml(""))

      assert %{"ok" => false, "output" => "no [s3] table in the config"} =
               PushArtifacts.run(%{
                 args: %{},
                 view: %{},
                 config_path: Fixtures.config_path(dir)
               })
    end
  end
end
