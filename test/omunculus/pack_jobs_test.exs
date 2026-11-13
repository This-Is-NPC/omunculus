defmodule Omunculus.PackJobsTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.{Config, Fixtures, Jobs, Store}
  alias Omunculus.Tools.Pack

  @jobs """
  [jobs]
  max_parallel = 2
  min_interval_minutes = 5
  max_jobs = 10
  missed = "skip"
  lateness_seconds = 60
  failures_before_pause = 3
  agent_may_create = false
  """

  @templates """

  [jobs.digest]
  agent = "chief"
  message = "Summarize the week."
  schedule = "daily at 09:00"
  timezone = "Europe/Paris"
  delivery = "owner_inbox"
  end_at = "2099-01-01T00:00:00Z"
  state = "active"

  [jobs.audit]
  workflow = "line"
  message = "Audit the open work."
  schedule = "every 2h"
  timezone = "UTC"
  state = "proposed"
  """

  @args %{"path" => "team", "models" => "lead=fast", "auth" => "vault=mine"}

  setup do
    dir = Fixtures.tmp_dir()
    toml = Path.join([Fixtures.pack(dir), "pack.toml"])
    File.write!(toml, File.read!(toml) <> @templates)
    %{dir: dir, toml: toml, config_path: Fixtures.write_pack_config(dir, @jobs)}
  end

  defp run_import(conn, config_path, args \\ %{}) do
    {:ok, jobs} = Jobs.list(conn)
    Pack.run(%{args: Map.merge(@args, args), config_path: config_path, view: %{"jobs" => jobs}})
  end

  defp apply_emits(conn, config_path, %{"emit" => emits}) do
    {:ok, config} = Config.load(config_path)

    ctx = %{
      run_id: nil,
      work_id: nil,
      author: "human",
      agent: nil,
      issuer: "local",
      subject: "1000",
      config: config,
      groups: %{}
    }

    Store.record_tools(
      conn,
      nil,
      [{%{name: "pack", args: %{}, ok: true, output: ""}, emits}],
      ctx
    )
  end

  test "the templates are not laid into the config", %{config_path: config_path} do
    assert %{"ok" => true} = Pack.run(%{args: @args, config_path: config_path, view: %{}})
    assert {:ok, %{agents: %{"chief" => _}}} = Config.load(config_path)
  end

  test "an import creates each template once, from the pack, owned by the importer",
       %{conn: conn, config_path: config_path} do
    assert %{"ok" => true, "output" => output} = result = run_import(conn, config_path)
    assert output =~ "jobs: 2 new of 2 templates"
    assert {:ok, _events} = apply_emits(conn, config_path, result)

    assert {:ok, [audit, digest]} = Jobs.list(conn)
    assert {audit["name"], audit["state"]} == {"team.audit", "proposed"}
    assert {digest["name"], digest["state"]} == {"team.digest", "active"}
    assert digest["agent"] == "chief"
    assert digest["delivery"] == "owner_inbox"
    assert digest["owner"] == %{"kind" => "human", "issuer" => "local", "subject" => "1000"}
    assert %{"channel" => "pack", "pack" => "team"} = digest["origin"]
  end

  test "importing again creates the missing jobs and leaves the existing ones",
       %{conn: conn, config_path: config_path} do
    assert {:ok, _} = apply_emits(conn, config_path, run_import(conn, config_path))

    assert %{"ok" => true, "output" => output, "emit" => []} = run_import(conn, config_path)
    assert output =~ "jobs: 0 new of 2 templates"

    assert {:ok, _} = Jobs.transition(conn, "team.audit", "archived", nil)
    assert {:ok, [%{"name" => "team.digest"}]} = Jobs.list(conn)

    assert %{"emit" => [%{"body" => %{"name" => "team.audit"}}]} = run_import(conn, config_path)
  end

  test "a template the config refuses stops the import before it writes anything",
       %{conn: conn, toml: toml, config_path: config_path} do
    File.write!(toml, String.replace(File.read!(toml), "every 2h", "every 1m"))

    assert %{"ok" => false, "output" => output} = run_import(conn, config_path)
    assert output =~ "job template audit"
    assert output =~ "min_interval_minutes"
    refute Map.has_key?(Toml.decode_file!(config_path), "packs")

    File.write!(toml, String.replace(File.read!(toml), "state = \"proposed\"", "state = \"on\""))

    assert %{"ok" => false, "output" => "cannot import team: job template audit: state" <> _} =
             run_import(conn, config_path)

    File.write!(toml, String.replace(File.read!(toml), "state = \"on\"", "owner = \"x\""))
    assert %{"ok" => false, "output" => output} = run_import(conn, config_path)
    assert output =~ "unknown key owner"
  end

  test "the system pack lets only the refiner and the auditor propose jobs" do
    assert {:ok, %{"agents" => agents}} =
             Config.Packs.read(Path.join(:code.priv_dir(:omunculus), "packs/system"))

    granted = for {name, %{"tools" => tools}} <- agents, "propose_job" in tools, do: name
    assert Enum.sort(granted) == ["auditor", "refiner"]
  end

  test "a project without [jobs] imports the pack and says the templates were skipped",
       %{dir: dir} do
    config_path = Fixtures.write_pack_config(dir)

    assert %{"ok" => true, "output" => output, "emit" => []} =
             Pack.run(%{args: @args, config_path: config_path, view: %{"jobs" => []}})

    assert output =~ "job templates skipped: the project has no [jobs] table"
  end
end
