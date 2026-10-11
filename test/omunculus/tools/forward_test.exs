defmodule Omunculus.Tools.ForwardTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures}
  alias Omunculus.Store.Query
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Forward

  import Omunculus.Fixtures, only: [role: 1]

  @works [
    %{id: "w1", title: "Bakery site", state: "open"},
    %{id: "w2", title: "Logo", state: "done"}
  ]

  defp forward(work_id),
    do:
      Forward.run(%{
        args: %{"work_id" => work_id, "message" => "make the header pink"},
        view: %{"works" => @works}
      })

  test "hands the message to an open work of the conversation" do
    assert forward("w1") == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "prompt",
                 "body" => %{"work_id" => "w1", "message" => "make the header pink"}
               }
             ]
           }
  end

  test "refuses a closed work, or one not under ## Works" do
    assert %{"ok" => false, "output" => "work w2 is done" <> _} = forward("w2")
    assert %{"ok" => false, "output" => "no work w9 under ## Works"} = forward("w9")
  end

  test "the builtin catalog discovers forward, ending the run" do
    assert %{"forward" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["model"]
    assert manifest.then == ["end"]
  end

  test "in the run cycle, a forwarded message opens a run of the work's agent" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)

    Fixtures.write_config(dir, """
    [agents.front]
    depth = 0
    text = "front"
    tools = ["end", "forward", "work"]

    [agents.clerk]
    depth = 0
    workflow_only = true
    text = "clerk"
    tools = ["comment", "end"]

    [workflows.desk]
    steps = [{ name = "talk", agent = "clerk" }]
    """)

    Fixtures.use_model(dir, fn assembled, _tools, call ->
      case {role(assembled), Regex.run(~r/\(work (\w+), open\)/, assembled)} do
        {"front", [_, id]} ->
          call.("forward", %{"work_id" => id, "message" => "more"})

        {"front", nil} ->
          call.("work", %{
            "report" => "opened",
            "works" => [%{"title" => "t", "goal" => "g", "workflow" => "desk"}]
          })

        {"clerk", _} ->
          call.("end", %{})
      end

      {:ok, ""}
    end)

    assert {:ok, _} = CLI.run(["send", "--agent", "front", "hi"], dir)
    assert {:ok, _} = CLI.run(["send", "--agent", "front", "more"], dir)

    project = Fixtures.open_project(dir)
    {:ok, runs} = Query.all(project.conn, "SELECT agent, via FROM runs WHERE work_id IS NOT NULL")
    assert %{agent: "clerk", via: "forward"} in runs
  end
end
