defmodule Omunculus.Process.CLITest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures, Project, ProcessFixtures}

  # A project on disk whose store holds the synthetic works.
  setup do
    dir = Fixtures.tmp_dir()
    Fixtures.write_config(dir, ProcessFixtures.config())
    project = Fixtures.open_project(dir)
    ProcessFixtures.seed(project.conn)
    Project.close(project)
    %{dir: dir}
  end

  test "process reads the project's log from the command line", %{dir: dir} do
    assert {:ok, output} =
             CLI.run(
               ["process", "--workflow", "delivery", "--support", "0.6", "--confidence", "0.9"],
               dir
             )

    assert output =~ "fitness 0.50"
    assert output =~ "response(write, bash)"
  end

  test "process prints a workflow's BPMN", %{dir: dir} do
    assert {:ok, xml} = CLI.run(["process", "--workflow", "delivery", "--bpmn", "to-be"], dir)
    assert String.starts_with?(xml, "<?xml")
  end

  test "ocel prints the log as OCEL 2.0 JSON, of its last conversations", %{dir: dir} do
    assert {:ok, json} = CLI.run(["ocel", "--last", "1"], dir)
    log = Jason.decode!(json)

    assert Enum.sort(Map.keys(log)) == ~w(eventTypes events objectTypes objects)
    assert log["objects"] |> Enum.filter(&(&1["type"] == "conversation")) |> length() == 1
  end

  test "ocel writes to a path relative to the project", %{dir: dir} do
    assert {:ok, output} = CLI.run(["ocel", "--out", "exports/log.json"], dir)
    path = Path.join(dir, "exports/log.json")

    assert output == "wrote #{path}"
    assert %{"events" => [_ | _]} = path |> File.read!() |> Jason.decode!()
  end

  test "ocel is not a model's tool", %{dir: dir} do
    {:ok, config} = Fixtures.load_config(dir)
    catalog = Omunculus.Tool.Catalog.discover(config.tools)
    assert catalog["ocel"].triggers == ["cli"]
    assert "model" in catalog["process"].triggers
  end
end
