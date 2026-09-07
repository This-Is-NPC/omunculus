defmodule Omunculus.ConfigShapeTest do
  @moduledoc "docs/to-be/config.md: the unified shape and the scenario fixtures."
  use ExUnit.Case, async: true

  alias Omunculus.Config

  @fixtures Path.expand("../fixtures/config", __DIR__)

  defp load(name) do
    Config.load(cwd: @fixtures, config_file: Path.join(@fixtures, name), env: %{})
  end

  test "keyed tables and [[arrays]] with name are the same shape" do
    dir = Path.join(System.tmp_dir!(), "omunculus-shape-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    keyed = Path.join(dir, "keyed.toml")
    array = Path.join(dir, "array.toml")

    File.write!(keyed, """
    [interceptors.audit]
    events = ["task.requested"]
    module = "Omunculus.Interceptors.Audit"

    [automations.log]
    events = ["task.completed"]
    run = "true"
    """)

    File.write!(array, """
    [[interceptors]]
    name = "audit"
    events = ["task.requested"]
    module = "Omunculus.Interceptors.Audit"

    [[automations]]
    name = "log"
    events = ["task.completed"]
    run = "true"
    """)

    {:ok, a} = Config.load(cwd: dir, config_file: keyed, env: %{})
    {:ok, b} = Config.load(cwd: dir, config_file: array, env: %{})
    assert a.interceptors == b.interceptors
    assert a.automations == b.automations
    File.rm_rf!(dir)
  end

  test "[profiles] absorbs [presets] and carries policy bands" do
    {:ok, config} = load("simple.toml")
    assert %{"count" => %{policy: %{"mode" => "deny", "granted" => ["counter"]}}} = config.presets
    assert config.presets["count"].instructions =~ "counter tool"
    # presets from Config.empty/0 remain available
    assert Map.has_key?(config.presets, "plan")
  end

  test "every base fixture loads and cross-references resolve" do
    for name <- ~w(simple.toml medium.toml medium-teams.toml complex.toml complex-teams.toml) do
      assert {:ok, _} = load(name), name
    end

    # The simple and medium levels are fully checkable today.
    for name <- ~w(simple.toml medium.toml medium-teams.toml) do
      {:ok, config} = load(name)
      assert {:ok, _} = Config.check(config), name
    end

    # The complex levels subscribe an automation to permission.requested,
    # which the catalog module does not declare yet. Remove this expectation
    # when permission negotiation lands.
    for name <- ~w(complex.toml complex-teams.toml) do
      {:ok, config} = load(name)

      assert {:error, {:unknown_event_type, "record", "permission.requested"}} =
               Config.check(config),
             name
    end

    {:ok, complex} = load("complex-teams.toml")
    assert complex.teams["code-review"].lead == "review-lead"
    assert complex.teams["code-review"].scope == "node"
    assert complex.workspaces["infra"].policy["human"] == ["edit", "write"]
    assert complex.policy["2"]["directory"] == "subtree"
    assert complex.session.cross_lineage == "routed"

    {:ok, base} = load("complex.toml")

    assert base.session.roles == %{
             "depth0" => "concierge",
             "depth1" => "repo-concierge",
             "depth2" => "worker"
           }

    assert [%{name: "record", may_request: %{"profiles" => ["count"]}}] = base.automations
  end

  test "the lane overlay references interceptors the spike does not have yet" do
    {:ok, lane} = load("lane.toml")
    assert length(lane.interceptors) == 4

    assert {:error, {:unknown_interceptor_module, "Omunculus.Interceptors.TeamGate"}} =
             Config.check(lane)
  end

  test "check rejects dangling references and bad policy values" do
    base = Config.empty()

    assert {:error, {:unknown_agent, "teams.t.lead", "ghost"}} =
             Config.check(%{
               base
               | teams: %{"t" => %{lead: "ghost", members: [], profile: nil, scope: nil}}
             })

    assert {:error, {:unknown_team, "w", "nope"}} =
             Config.check(%{
               base
               | workspaces: %{"w" => %{roots: ["."], teams: ["nope"], policy: %{}}}
             })

    assert {:error, {:invalid_policy_mode, "policy.depth.0", "maybe"}} =
             Config.check(%{base | policy: %{"0" => %{"mode" => "maybe"}}})

    assert {:error, {:invalid_team_scope, "t", "global"}} =
             Config.check(%{
               base
               | agents: %{"a" => %{prompt: nil, model: nil, max_turns: nil}},
                 teams: %{"t" => %{lead: "a", members: [], profile: nil, scope: "global"}}
             })

    assert {:error, {:unknown_profile, "automations.x.may_request", "fix"}} =
             Config.check(%{
               base
               | automations: [
                   %{
                     name: "x",
                     events: ["run.failed"],
                     run: "true",
                     may_request: %{"profiles" => ["fix"]}
                   }
                 ]
             })
  end
end
