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

  test "lists the workspaces with the default one, and keeps model secrets out of the setup" do
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

    assert described["root"] == dir
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

    refute described |> Map.drop(["document"]) |> Jason.encode!() =~ "secret"
    refute Jason.encode!(described) =~ "secret-key"
    assert described["literal_keys"] == ["openrouter"]
  end

  test "adds the tables an editor writes, the file's revision and the ceiling names" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    path = Fixtures.config_path(dir)
    described = describe(path)

    assert Map.keys(described["document"]) == ~w(agents auth models policy workflows)
    assert described["literal_keys"] == []
    assert described["document"]["agents"]["worker"]["human"] == ["sandbox.write"]

    assert described["revision"] ==
             :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

    assert Enum.all?(~w(work done store sandbox.write), &(&1 in described["names"]))
    refute "send" in described["names"]
  end

  test "fails without a config path" do
    assert %{"ok" => false, "output" => "config_path required"} = Config.run(%{})
  end

  test "says which packs the project imports and what each brings" do
    dir = Fixtures.tmp_dir()
    pack = Fixtures.pack(dir)

    path =
      Fixtures.write_pack_config(
        dir,
        ~s([[packs]]\npath = "team"\nmodels = { lead = "fast" }\nauth = { vault = "mine" }\ndepth = 1\n)
      )

    assert %{"ok" => true, "output" => output} = Omunculus.Tools.Config.run(%{config_path: path})

    assert [
             %{
               "name" => "team",
               "path" => ^pack,
               "depth" => 1,
               "models" => %{"lead" => "fast"},
               "agents" => ["chief", "hand"],
               "workflows" => ["line"]
             }
           ] = Jason.decode!(output)["packs"]
  end

  test "the builtin catalog discovers config for the command line and models" do
    assert %{"config" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["cli", "model"]
  end
end
