defmodule Omunculus.Tools.ArtifactsToolsTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Artifacts, Config, ExecutionPolicyFixtures, Fixtures, Project, Run, Store}
  alias Omunculus.Store.Query
  alias Omunculus.Tools.{Attach, GetArtifact, ListArtifacts, Out, PutArtifact}

  setup do
    dir = Fixtures.tmp_dir()

    Fixtures.write_config(
      dir,
      "[agents.concierge]\ndepth = 0\ntext = \"c\"\n" <>
        ~s([store]\npath = "s.sqlite3"\nattachments = "files"\nattachment_bytes = 256\n)
    )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(root)
    {:ok, config} = Config.load(Fixtures.config_path(dir))
    %{dir: dir, config_path: Fixtures.config_path(dir), store: config.store, root: root}
  end

  defp version(ctx, name, kind, number, content, media_type \\ "text/plain") do
    {:ok, meta} = Artifacts.put(ctx.store, name, kind, media_type, content)
    Map.merge(meta, %{"kind" => kind, "version" => number, "by" => "seller", "at" => "now"})
  end

  describe "put_artifact" do
    test "emits an artifact action for data, or for content with its media type" do
      assert %{"ok" => true, "output" => "put quote version 1", "emit" => [emit]} =
               PutArtifact.run(%{
                 args: %{"name" => "quote", "kind" => "proposal", "data" => %{"total" => 10}},
                 view: %{}
               })

      assert %{"type" => "artifact", "body" => body} = emit

      assert %{"name" => "quote", "kind" => "proposal", "media_type" => "application/json"} =
               body

      assert Jason.decode!(body["content"]) == %{"total" => 10}

      view = %{"artifacts" => [%{"name" => "brief", "version" => 1}]}

      assert %{"output" => "put brief version 2", "emit" => [%{"body" => body}]} =
               PutArtifact.run(%{
                 args: %{
                   "name" => "brief",
                   "kind" => "brief",
                   "content" => "# Brief",
                   "media_type" => "text/markdown",
                   "note" => "second"
                 },
                 view: view
               })

      assert %{"content" => "# Brief", "media_type" => "text/markdown", "note" => "second"} = body
    end

    test "refuses what is not whole" do
      put = &PutArtifact.run(%{args: &1, view: %{}})

      assert put.(%{"kind" => "brief", "data" => %{}}) == Out.fail("name required")

      assert %{"ok" => false, "output" => "give data, or content" <> _} =
               put.(%{"name" => "a", "kind" => "b"})

      assert %{"ok" => false, "output" => "data is the whole content" <> _} =
               put.(%{"name" => "a", "kind" => "b", "data" => %{}, "content" => "x"})

      assert put.(%{"name" => "a", "kind" => "b", "data" => "x"}) ==
               Out.fail("data must be an object")
    end
  end

  describe "get_artifact and list_artifacts" do
    test "get reads the latest version, or the one named, and refuses what is not text", ctx do
      view = %{
        "artifacts" => [
          version(ctx, "brief", "brief", 1, "one"),
          version(ctx, "brief", "brief", 2, "two"),
          version(ctx, "logo", "design", 1, <<137, 80, 78, 71, 228>>, "image/png")
        ]
      }

      get = &GetArtifact.run(%{args: &1, view: view, config_path: ctx.config_path})

      assert get.(%{"name" => "brief"}) == Out.ok("two")
      assert get.(%{"name" => "brief", "version" => 1}) == Out.ok("one")

      assert get.(%{"name" => "brief", "version" => 3}) ==
               Out.fail("no such version of brief in this conversation")

      assert get.(%{"name" => "nothing"}) ==
               Out.fail("no such version of nothing in this conversation")

      assert get.(%{"name" => "logo"}) == Out.fail(Out.not_text("logo", 5))
    end

    test "list groups the versions by artifact and filters by kind", ctx do
      view = %{
        "artifacts" => [
          version(ctx, "brief", "brief", 1, "one"),
          version(ctx, "plan", "design", 1, "x"),
          version(ctx, "brief", "brief", 2, "two")
        ]
      }

      list = &ListArtifacts.run(%{args: &1, view: view})

      assert %{"output" => output} = list.(%{})
      assert [brief, plan] = String.split(output, "\n")
      assert brief =~ "- brief (brief): v1 text/plain 3 bytes by seller, v2 text/plain 3 bytes"
      assert plan =~ "- plan (design): v1"

      assert list.(%{"kind" => "design"})["output"] =~ "plan"
      refute list.(%{"kind" => "design"})["output"] =~ "brief"
      assert list.(%{"kind" => "preview"}) == Out.ok("no artifacts")
    end
  end

  describe "attach by reference" do
    defp attach(args, view, %{config_path: config_path, root: root}) do
      input = %{args: args, view: view, roots: [root], config_path: config_path}
      Attach.run(input, ExecutionPolicyFixtures.policy([root]))
    end

    test "hands the exact version, the latest when none is named", ctx do
      v1 = version(ctx, "proposal.md", "document", 1, "price 10")
      v2 = version(ctx, "proposal.md", "document", 2, "price 12")
      view = %{"artifacts" => [v1, v2]}

      assert %{"ok" => true, "emit" => [%{"type" => "attach", "body" => body}]} =
               attach(%{"artifact" => "proposal.md"}, view, ctx)

      assert %{"note" => "proposal.md version 2", "attachments" => [meta]} = body
      assert meta == Map.take(v2, ~w(name media_type bytes sha256))

      assert %{"emit" => [%{"body" => %{"attachments" => [first], "note" => "the first"}}]} =
               attach(
                 %{"artifact" => "proposal.md", "version" => 1, "note" => "the first"},
                 view,
                 ctx
               )

      assert first["sha256"] == v1["sha256"]
    end

    test "refuses an unknown version and both a path and an artifact", ctx do
      assert attach(%{"artifact" => "x"}, %{"artifacts" => []}, ctx) ==
               Out.fail("no such version of x in this conversation")

      assert attach(%{"artifact" => "x", "path" => "y"}, %{}, ctx) ==
               Out.fail("give path or artifact, not both")

      assert attach(%{}, %{}, ctx) == Out.fail("give path, or artifact")
    end
  end

  # The harness gives each call the artifacts of the run's conversation,
  # with their data when the manifest asks for it, and the store numbers them.
  test "a run puts, lists, reads and attaches artifacts of its conversation", %{dir: dir} do
    Fixtures.write_config(
      dir,
      """
      [agents.concierge]
      depth = 0
      text = "hi"
      tools = ["put_artifact", "get_artifact", "list_artifacts", "attach"]

      [store]
      path = "s.sqlite3"
      attachments = "files"
      attachment_bytes = 256
      """
    )

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

    test_pid = self()

    model = fn _assembled, _tools, call ->
      {:ok, put} =
        call.("put_artifact", %{
          "name" => "b",
          "kind" => "brief",
          "content" => "v1",
          "media_type" => "text/plain"
        })

      {:ok, _} =
        call.("put_artifact", %{
          "name" => "b",
          "kind" => "brief",
          "content" => "v2",
          "media_type" => "text/plain"
        })

      {:ok, list} = call.("list_artifacts", %{})
      {:ok, get} = call.("get_artifact", %{"name" => "b", "version" => 1})
      {:ok, attach} = call.("attach", %{"artifact" => "b", "version" => 1})
      send(test_pid, {:calls, put, list, get, attach})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)
    assert {:ok, _run} = Run.open(project, Fixtures.opening(message_id))

    assert_receive {:calls, put, list, get, attach}
    assert put =~ "put b version 1"
    assert list =~ "- b (brief): v1"
    assert list =~ "v2"
    assert get =~ "v1"
    assert attach =~ "attached b"

    assert {:ok, [v1, v2]} = Store.artifacts(project.conn, conversation_id)
    assert [v1["version"], v2["version"]] == [1, 2]

    assert {:ok, [attached]} = Store.attachments(project.conn, conversation_id)
    assert attached["sha256"] == v1["sha256"]
    assert attached["note"] == nil

    Project.close(project)
  end
end
