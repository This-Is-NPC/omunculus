defmodule Omunculus.Tools.ConfigureTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures}
  alias Omunculus.Tool.Catalog

  setup do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    %{dir: dir, path: Fixtures.config_path(dir)}
  end

  defp read(dir) do
    {:ok, output} = CLI.run(["config", "--whole", "true"], dir)
    Jason.decode!(output)
  end

  defp configure(dir, item, value, extra \\ []) do
    revision = Keyword.get_lazy(extra, :revision, fn -> read(dir)["revision"] end)
    from = if extra[:from], do: ["--from", extra[:from]], else: []

    CLI.run(
      ["configure", "--item", item, "--value", Jason.encode!(value), "--revision", revision] ++
        from,
      dir
    )
  end

  test "writes one item and keeps the rest of the file", ctx do
    before = Toml.decode_file!(ctx.path)
    worker = Map.put(before["agents"]["worker"], "text", "You build.\nThen report.")

    assert {:ok, ""} = configure(ctx.dir, "agents.worker", worker)

    written = Toml.decode_file!(ctx.path)
    assert written["agents"]["worker"]["text"] == "You build.\nThen report."
    assert put_in(before, ["agents", "worker"], worker) == written
  end

  test "writes a whole table for policy and removes an item for null", ctx do
    policy = Map.put(read(ctx.dir)["document"]["policy"], "max_retries", 5)
    assert {:ok, ""} = configure(ctx.dir, "policy", policy)
    assert Toml.decode_file!(ctx.path)["policy"]["max_retries"] == 5

    workflows = read(ctx.dir)["document"]["workflows"]
    assert {:ok, ""} = configure(ctx.dir, "workflows.delivery", nil)
    refute Map.has_key?(Toml.decode_file!(ctx.path)["workflows"] || %{}, "delivery")
    assert Map.has_key?(workflows, "delivery")
  end

  test "renames an item in one write", ctx do
    worker = read(ctx.dir)["document"]["agents"]["worker"]

    # While the delivery workflow names worker, a rename leaves it without its agent.
    assert {:error, {:tool_failed, _reason}} =
             configure(ctx.dir, "agents.builder", worker, from: "worker")

    assert {:ok, ""} = configure(ctx.dir, "workflows.delivery", nil)
    assert {:ok, ""} = configure(ctx.dir, "agents.builder", worker, from: "worker")

    agents = Toml.decode_file!(ctx.path)["agents"]
    assert agents["builder"] == worker
    refute Map.has_key?(agents, "worker")
  end

  test "keeps a provider's literal key out of the document and in the file", ctx do
    File.write!(
      ctx.path,
      File.read!(ctx.path) <>
        """

        [auth]
        store = "auth.json"

        [auth.remote]
        kind = "api_key"
        key = "secret-key"

        [auth.env]
        kind = "api_key"
        key = "$REMOTE_KEY"
        """
    )

    described = read(ctx.dir)
    assert described["literal_keys"] == ["remote"]
    assert described["document"]["auth"]["remote"] == %{"kind" => "api_key"}
    assert described["document"]["auth"]["env"]["key"] == "$REMOTE_KEY"
    refute Jason.encode!(described) =~ "secret-key"

    assert {:ok, ""} = configure(ctx.dir, "auth.remote", %{"kind" => "api_key"})
    assert Toml.decode_file!(ctx.path)["auth"]["remote"]["key"] == "secret-key"

    assert {:ok, ""} = configure(ctx.dir, "auth.remote", %{"kind" => "api_key", "key" => "!pass"})
    assert Toml.decode_file!(ctx.path)["auth"]["remote"]["key"] == "!pass"
  end

  test "binds a tool's secrets to a provider", ctx do
    File.write!(ctx.path, "\n[auth]\nstore = \"auth.json\"\n", [:append])
    assert {:ok, ""} = configure(ctx.dir, "auth.gh", %{"kind" => "api_key", "key" => "$GH_TOKEN"})
    assert {:ok, ""} = configure(ctx.dir, "secrets.github", %{"GH_TOKEN" => "gh"})
    assert Toml.decode_file!(ctx.path)["secrets"] == %{"github" => %{"GH_TOKEN" => "gh"}}
    assert read(ctx.dir)["document"]["secrets"] == %{"github" => %{"GH_TOKEN" => "gh"}}

    assert {:error, {:tool_failed, _unknown_provider}} =
             configure(ctx.dir, "secrets.github", %{"GH_TOKEN" => "missing"})
  end

  test "refuses a file changed since it was read", ctx do
    revision = read(ctx.dir)["revision"]
    File.write!(ctx.path, File.read!(ctx.path) <> "\n")
    before = File.read!(ctx.path)

    assert {:error, {:tool_failed, "omunculus.toml changed since it was read; read it again"}} =
             configure(ctx.dir, "policy", %{}, revision: revision)

    assert File.read!(ctx.path) == before
  end

  test "refuses a result that does not load, and leaves the file", ctx do
    before = File.read!(ctx.path)
    worker = read(ctx.dir)["document"]["agents"]["worker"]

    assert {:error, {:tool_failed, _reason}} =
             configure(ctx.dir, "agents.worker", Map.put(worker, "model", "missing"))

    assert File.read!(ctx.path) == before
  end

  test "refuses an item it does not edit, a null inside a table and text that is not JSON",
       ctx do
    message =
      "the item is not agents, models, workflows, workspaces, auth or secrets .<name>, policy or access, " <>
        "with a JSON table or null"

    for {item, value} <- [
          {"store", %{"path" => "elsewhere.sqlite3"}},
          {"auth.store", %{"kind" => "api_key"}},
          {"agents", %{}},
          {"agents.worker", %{"text" => nil}},
          {"agents.worker", "text"}
        ] do
      assert {:error, {:tool_failed, ^message}} = configure(ctx.dir, item, value)
    end

    revision = read(ctx.dir)["revision"]

    assert {:error, {:tool_failed, ^message}} =
             CLI.run(
               ["configure", "--item", "policy", "--value", "{", "--revision", revision],
               ctx.dir
             )
  end

  test "the builtin catalog discovers configure for the command line and a reply's chain" do
    assert %{"configure" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["cli", "chain"]
  end
end
