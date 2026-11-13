defmodule Omunculus.Jobs.PolicyTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Config, Errors, Fixtures}

  @valid %{
    "max_parallel" => 2,
    "min_interval_minutes" => 5,
    "max_jobs" => 50,
    "missed" => "run_once",
    "lateness_seconds" => 90,
    "failures_before_pause" => 3,
    "agent_may_create" => true
  }

  alias Omunculus.Jobs.Policy

  test "a project without the table has no jobs" do
    assert {:ok, nil} = Policy.parse(nil)
    assert %Config{jobs: nil} = Fixtures.config()
  end

  test "the table loads as the TOML gives it" do
    config =
      Fixtures.config("""
      [agents.front]
      depth = 0
      text = "front"

      [jobs]
      max_parallel = 2
      min_interval_minutes = 5
      max_jobs = 50
      missed = "run_once"
      lateness_seconds = 90
      failures_before_pause = 3
      agent_may_create = true
      """)

    assert config.jobs == %{
             max_parallel: 2,
             min_interval_minutes: 5,
             max_jobs: 50,
             missed: "run_once",
             lateness_seconds: 90,
             failures_before_pause: 3,
             agent_may_create: true
           }
  end

  test "every key is required and checked, and each refusal reads in words" do
    assert {:ok, _} = Policy.parse(@valid)

    cases = [
      {Map.delete(@valid, "max_jobs"), "must give max_jobs: it has no default"},
      {Map.put(@valid, "extra", 1), "has an unknown key extra"},
      {%{@valid | "max_parallel" => 0}, "max_parallel must be a positive integer"},
      {%{@valid | "lateness_seconds" => "soon"}, "lateness_seconds must be a positive integer"},
      {%{@valid | "missed" => "later"}, "missed must be skip or run_once"},
      {%{@valid | "agent_may_create" => "yes"}, "agent_may_create must be true or false"}
    ]

    for {table, words} <- cases do
      assert {:error, reason} = Policy.parse(table)
      assert Errors.format(reason) =~ words
    end

    assert {:error, {:jobs, :invalid}} = Policy.parse("nope")
  end

  test "access roles may hold the job capabilities, a conversation role too" do
    toml = """
    [agents.front]
    depth = 0
    text = "front"

    [access]
    creator_role = "owner"
    bootstrap_role = "admin"

    [access.roles.admin]
    scope = "project"
    capabilities = ["project.manage_access", "project.manage_config", "conversation.manage_access", "job.create", "job.manage", "job.read"]

    [access.roles.owner]
    scope = "conversation"
    capabilities = ["conversation.manage_access", "job.read"]
    """

    assert %Config{
             access: %{
               roles: %{"owner" => %{capabilities: ["conversation.manage_access", "job.read"]}}
             }
           } =
             Fixtures.config(toml)
  end
end
