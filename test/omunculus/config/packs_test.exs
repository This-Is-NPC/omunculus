defmodule Omunculus.Config.PacksTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Config, Fixtures}

  setup do
    dir = Fixtures.tmp_dir()
    %{dir: dir, pack: Fixtures.pack(dir)}
  end

  defp load(dir, toml), do: Config.load(Fixtures.write_pack_config(dir, toml))

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

  test "a pack imported depths below its own moves its agents and depth layers down",
       %{dir: dir} do
    assert {:ok, config} =
             load(
               dir,
               String.replace(@imports, "path = \"team\"\n", "path = \"team\"\ndepth = 1\n")
             )

    assert %{depth: 1} = config.agents["chief"]
    assert %{depth: 2} = config.agents["hand"]
    assert Config.workflows_for(config, 2) == ["line"]
    assert Config.workflows_for(config, 1) == []
  end

  test "two packs requiring workflows at one depth add them up", %{dir: dir} do
    other = Path.join(dir, "other")
    File.mkdir_p!(other)

    File.write!(Path.join(other, "pack.toml"), """
    [pack]
    name = "other"
    roles = ["lead"]

    [agents.smith]
    depth = 1
    model = "lead"
    text = "smith"
    tools = ["end"]

    [workflows.forge]
    steps = [{ name = "shape", agent = "smith" }]

    [policy.depth.1]
    workflows = ["forge"]
    """)

    assert {:ok, config} =
             load(dir, @imports <> ~s([[packs]]\npath = "other"\nmodels = { lead = "fast" }\n))

    assert Config.workflows_for(config, 1) == ["line", "forge"]
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
