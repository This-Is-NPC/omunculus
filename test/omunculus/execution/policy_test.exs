defmodule Omunculus.Execution.PolicyTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Ceiling, Config, Id, Project}
  alias Omunculus.Config.Layer
  alias Omunculus.Execution.Policy

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp snapshot(config, agent, names, grants) do
    Ceiling.mount(
      config,
      %{
        agent: agent,
        depth: config.agents[agent].depth,
        grants: grants,
        stage: nil,
        workspace: nil,
        groups: %{}
      },
      names
    )
  end

  defp policy(
         config,
         agent,
         dir,
         names \\ ["bash", "sandbox.write", "sandbox.network"],
         grants \\ []
       ) do
    Policy.build(
      config,
      snapshot(config, agent, names, grants),
      %{name: nil, root: nil},
      dir,
      names
    )
  end

  test "builds a read-only, network-free policy for an ungranted run", %{dir: dir} do
    {:ok, config} = Config.load(dir)

    assert {:ok, policy} = policy(config, "concierge", dir)

    assert policy.workspace == %{name: nil, root: dir}
    assert policy.read_only == [dir]
    assert policy.read_write == []
    assert policy.network == "none"
    assert policy.hidden == [Path.join(dir, ".omunculus"), Path.join(dir, "omunculus.toml")]

    serializable = Policy.serializable(policy)
    assert serializable["backend"] == "bubblewrap"
    assert serializable["environment"] == ["LANG", "LC_ALL", "TERM"]
    refute Map.has_key?(serializable, "environment_values")
    assert String.length(serializable["id"]) == 64
  end

  test "grants sandbox resources independently for workspace writes and network access", %{
    dir: dir
  } do
    {:ok, config} = Config.load(dir)

    assert {:ok, policy} =
             policy(config, "worker", dir, ["sandbox.write", "sandbox.network"], [
               "sandbox.network"
             ])

    assert policy.read_only == []
    assert policy.read_write == [dir]
    assert policy.network == "host"
  end

  test "keeps denied paths hidden below a writable workspace", %{dir: dir} do
    private = Path.join(dir, "private")
    File.mkdir_p!(private)
    {:ok, config} = Config.load(dir)
    worker = config.agents["worker"]
    ceiling = %Layer{worker.ceiling | deny: ["./private"]}
    config = %{config | agents: Map.put(config.agents, "worker", %{worker | ceiling: ceiling})}

    assert {:ok, policy} = policy(config, "worker", dir)

    assert policy.read_write == [dir]
    assert private in policy.hidden
  end

  test "mounts granted external paths read-only", %{dir: dir} do
    external = Path.join(System.tmp_dir!(), Id.new())
    File.write!(external, "external")
    on_exit(fn -> File.rm(external) end)

    {:ok, config} = Config.load(dir)
    worker = config.agents["worker"]
    ceiling = %Layer{worker.ceiling | granted: worker.ceiling.granted ++ [external]}
    config = %{config | agents: Map.put(config.agents, "worker", %{worker | ceiling: ceiling})}

    assert {:ok, policy} =
             policy(config, "worker", dir, [external, "sandbox.write", "sandbox.network"])

    assert policy.read_write == [dir]
    assert policy.read_only == [external]
  end

  test "rejects a runtime root that exposes the user home", %{dir: dir} do
    {:ok, config} = Config.load(dir)
    config = %{config | execution: %{config.execution | runtimes: ["/"]}}

    assert {:error, {:runtime, "/", :overlaps_protected_path}} = policy(config, "concierge", dir)
  end

  test "rejects an unnamed project workspace that contains a named workspace", %{dir: dir} do
    nested = Path.join(dir, "nested")
    File.mkdir_p!(nested)
    {:ok, config} = Config.load(dir)
    config = %{config | workspaces: %{"nested" => %{root: nested, ceiling: %Layer{}}}}

    assert {:error, {:workspace, {:contains_workspace, "nested"}}} =
             policy(config, "concierge", dir)
  end

  test "keeps the harness state in a dedicated directory", %{dir: dir} do
    assert Project.state_dir(dir) == Path.join(dir, ".omunculus")
  end
end
