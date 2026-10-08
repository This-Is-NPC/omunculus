defmodule Omunculus.Tools.ConfigTest do
  use ExUnit.Case, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Config

  defp describe(path) do
    assert %{"ok" => true, "output" => output, "emit" => []} = Config.run(%{config_path: path})
    Jason.decode!(output)
  end

  test "describes the default preset's agents, model and workflow" do
    described = describe(Path.join(Fixtures.preset_dir("default"), "omunculus.toml"))

    assert [%{"name" => "concierge", "depth" => 0, "model" => "fake"} | _] = described["agents"]

    assert %{"name" => "worker", "depth" => 1, "human" => ["sandbox.write"]} =
             Enum.find(described["agents"], &(&1["name"] == "worker"))

    assert [%{"name" => "fake", "api" => "module", "provider" => nil, "model" => nil}] =
             described["models"]

    assert described["workspaces"] == []
    assert described["workspace"] == nil

    assert [
             %{
               "name" => "delivery",
               "steps" => [
                 %{"name" => "to_do", "agent" => "worker"},
                 %{"name" => "review", "agent" => "reviewer"}
               ]
             }
           ] =
             described["workflows"]
  end

  test "lists the workspaces with the default one, and keeps model secrets out" do
    dir = Fixtures.tmp_dir()
    root = Path.join(dir, "site")
    File.mkdir_p!(root)

    Fixtures.write_config(dir, """
    [workspaces.site]
    root = "#{root}"

    [policy]
    workspace = "site"
    assemble = "assemble"
    max_retries = 1

    [auth]
    store = "auth.json"

    [auth.openrouter]
    kind = "api_key"
    key = "secret-key"

    [models.remote]
    api = "openai-completions"
    provider = "openrouter"
    url = "https://openrouter.ai/api/v1"
    model = "openai/gpt-6-luna"
    timeout_ms = 1000
    headers = { authorization = "Bearer secret" }

    [agents.concierge]
    depth = 0
    model = "remote"
    text = "concierge"
    """)

    described = describe(Fixtures.config_path(dir))

    assert described["workspaces"] == [%{"name" => "site", "root" => root}]
    assert described["workspace"] == "site"

    assert [
             %{
               "name" => "remote",
               "api" => "openai-completions",
               "provider" => "openrouter",
               "model" => "openai/gpt-6-luna"
             }
           ] =
             described["models"]

    refute Jason.encode!(described) =~ "secret"
  end

  test "fails without a config path" do
    assert %{"ok" => false, "output" => "config_path required"} = Config.run(%{})
  end

  test "the builtin catalog discovers config with triggers == [\"cli\"]" do
    assert %{"config" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["cli"]
  end
end
