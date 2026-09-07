defmodule Omunculus.CLI.ConfigCheckTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Omunculus.{Config, Policy}

  @fixtures Path.expand("../../fixtures/config", __DIR__)

  defp load(name) do
    Config.load(cwd: @fixtures, config_file: Path.join(@fixtures, name), env: %{})
  end

  test "simple and medium fixtures pass policy fit" do
    for name <- ~w(simple.toml medium.toml) do
      {:ok, config} = load(name)
      assert {:ok, %{policy: policy}} = Config.check(config), name
      assert is_map(policy)
      assert policy != %{}
    end
  end

  test "count profile fits depth 0 workspace app on simple" do
    {:ok, config} = load("simple.toml")
    {:ok, %{policy: policy}} = Config.check(config)

    assert %{
             "granted" => ["counter"],
             "negotiable" => [],
             "human" => [],
             "forbidden" => _forbidden
           } = Policy.line(policy, "count", "0", "app") |> elem(1)
  end

  test "config check prints policy bands for simple fixture" do
    path = Path.join(@fixtures, "simple.toml")

    output =
      capture_io(fn ->
        assert Omunculus.CLI.dispatch(
                 ["config", "check", "--config", path],
                 %{}
               ) == 0
      end)

    assert output =~ "profile=count depth=0 workspace=app"
    assert output =~ "granted counter"
    assert output =~ "profile=coding depth=0 workspace=app"
  end

  test "stale tools_catalog pin is rejected" do
    dir = Path.join(System.tmp_dir!(), "omunculus-catalog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "stale.toml")

    File.write!(path, """
    [session]
    tools_catalog = "0"

    [workspaces.app]
    roots = ["."]
    mode = "allow"
    """)

    {:ok, config} = Config.load(cwd: dir, config_file: path, env: %{})

    assert {:error, {:stale_tools_catalog, "0", "1"}} = Config.check(config)

    File.rm_rf!(dir)
  end

  test "profile bands intersect with ceiling in the policy table" do
    dir = Path.join(System.tmp_dir!(), "omunculus-ceiling-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "bad.toml")

    File.write!(path, """
    [workspaces.app]
    roots = ["."]
    mode = "deny"
    granted = ["read"]

    [profiles.coding]
    mode = "deny"
    granted = ["read"]

    [profiles.plan]
    mode = "deny"
    granted = ["read"]

    [profiles.writer]
    mode = "deny"
    granted = ["edit"]
    """)

    {:ok, config} = Config.load(cwd: dir, config_file: path, env: %{})

    assert {:ok, %{policy: policy}} = Config.check(config)

    assert {:ok, bands} = Policy.line(policy, "writer", "0", "app")
    assert bands["granted"] == []
    assert "edit" in bands["forbidden"]

    File.rm_rf!(dir)
  end
end
