defmodule Omunculus.Config.PacksTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Config, Fixtures}

  setup do
    dir = Fixtures.tmp_dir()
    pack = Path.join(dir, "team")
    File.mkdir_p!(Path.join(pack, "tools"))

    File.write!(Path.join(pack, "pack.toml"), """
    [pack]
    name = "team"
    roles = ["lead"]
    auth = ["vault"]

    [agents.chief]
    depth = 0
    model = "lead"
    text = "chief"
    tools = ["end"]

    [agents.hand]
    depth = 1
    model = "lead"
    text = "hand"
    tools = ["end"]

    [workflows.line]
    steps = [{ name = "make", agent = "hand" }]

    [secrets.deploy]
    KEY = "vault"

    [policy.depth.1]
    workflow = "line"
    """)

    %{dir: dir, pack: pack}
  end

  defp load(dir, toml) do
    Fixtures.write_config(dir, """
    [models.fast]
    api = "module"
    module = "Omunculus.Model.Fake"

    [auth]
    store = "auth.json"

    [auth.mine]
    kind = "api_key"
    key = "secret"

    #{toml}
    """)

    Config.load(Fixtures.config_path(dir))
  end

  @imports ~s([[packs]]\npath = "team"\nmodels = { lead = "fast" }\nauth = { vault = "mine" }\n)

  test "lays the pack under the config: its roles and providers bound, its tools first",
       %{dir: dir, pack: pack} do
    assert {:ok, config} = load(dir, @imports)

    assert %{chief: %{model: "fast"}, hand: %{model: "fast"}} =
             Map.new(config.agents, fn {name, agent} -> {String.to_atom(name), agent} end)

    assert [%{agent: "hand"}] = config.workflows["line"]
    assert config.secrets["deploy"] == %{"KEY" => "mine"}
    assert hd(config.tools.paths) == Path.join(pack, "tools")
  end

  test "an item of the config overrides the pack's key by key", %{dir: dir} do
    assert {:ok, config} = load(dir, @imports <> ~s([agents.hand]\ngranted = ["write"]\n))

    assert %{text: "hand", depth: 1} = config.agents["hand"]
    assert config.agents["hand"].ceiling.granted == ["end", "write"]
  end

  test "refuses what it cannot bind or lay", %{dir: dir, pack: pack} do
    other = Path.join(dir, "other")
    File.mkdir_p!(other)
    File.cp!(Path.join(pack, "pack.toml"), Path.join(other, "pack.toml"))

    for {toml, reason} <- [
          {~s([[packs]]\npath = "team"\nmodels = {}\nauth = { vault = "mine" }\n),
           {"team", :models, {:unmapped, "lead"}}},
          {~s([[packs]]\npath = "team"\nmodels = { lead = "fast", extra = "fast" }\nauth = { vault = "mine" }\n),
           {"team", :models, {:unknown, "extra"}}},
          {~s([[packs]]\npath = "nowhere"\n), {:no_pack, Path.join(dir, "nowhere")}},
          {@imports <> String.replace(@imports, ~s(path = "team"), ~s(path = "other")),
           {"team", :conflict, {"agents", "chief", "team"}}}
        ] do
      assert {:error, {:packs, ^reason}} = load(dir, toml), inspect(reason)
    end
  end
end
