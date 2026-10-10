defmodule Omunculus.Tools.ReadWorkTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures}
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.ReadWork

  @input %{name: "read_work", args: %{}, view: %{}, run_id: nil, work_id: nil}

  test "renders the work, its comments and each run's record without the opening call" do
    tool = fn name, output ->
      %{type: "tool", body: Jason.encode!(%{name: name, args: %{}, ok: true, output: output})}
    end

    work = %{
      title: "Answer",
      assignee: "worker",
      state: "done",
      stage: nil,
      goal: "answer the greeting",
      comments: [%{author: "agent", body: "said hello back"}],
      runs: [
        %{
          agent: "worker",
          via: "delegate",
          message: nil,
          events: [
            %{type: "start-run", body: "{}"},
            tool.("assemble", "the whole prompt"),
            %{type: "model", body: ~s({"content":"hello"})},
            tool.("write", "")
          ]
        }
      ]
    }

    output = ReadWork.run(%{@input | view: %{"target" => work}})["output"]

    assert output ==
             Enum.join(
               [
                 "# Answer",
                 "agent: worker · state: done",
                 "## Goal\nanswer the greeting",
                 "## Comments\n- agent: said hello back",
                 "## Run 1 — worker, via delegate\n- model {\"content\":\"hello\"}\n- tool write {} ok"
               ],
               "\n\n"
             )
  end

  test "without a target it says what work_id must name" do
    assert %{"ok" => false} = ReadWork.run(@input)
  end

  test "the builtin manifest is a model tool in the store group reading a descendant" do
    assert %{"read_work" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["model"]
    assert "store" in manifest.groups

    assert [%{key: "target", source: "works", from: ["args.work_id"], within: "descendants"}] =
             manifest.views
  end

  test "a parent reads its child, and nothing outside what it handed down" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    test_pid = self()

    model = fn assembled, _tools, call ->
      cond do
        assembled =~ "You are the worker." ->
          call.("done", %{"report" => "said hello back"})

        assembled =~ "\n\n## Results\n" ->
          [_, child] = Regex.run(~r/work (\w+)\)/, assembled)
          send(test_pid, {:child, call.("read_work", %{"work_id" => child})})
          send(test_pid, {:own, call.("read_work", %{"work_id" => root_id(assembled)})})
          call.("done", %{"report" => "checked"})

        assembled =~ "## Last comment\nopened" ->
          call.("work", %{
            "report" => "delegated",
            "works" => [%{"title" => "Answer", "goal" => "answer the greeting"}]
          })

        true ->
          call.("work", %{
            "report" => "opened",
            "works" => [%{"title" => "Root", "goal" => "r", "agent" => "concierge"}]
          })
      end

      {:ok, "unused"}
    end

    Fixtures.use_model(dir, model)
    assert {:ok, ""} = CLI.run(["send", "Alo"], dir)

    assert_received {:child, {:ok, read}}
    assert read =~ "# Answer"
    assert read =~ "- agent: said hello back"
    assert read =~ "## Run 1 — worker, via delegate"

    assert_received {:own, {:error, _outside}}
  end

  # The root's id, from the record of its own last run.
  defp root_id(assembled) do
    [_, id] = Regex.run(~r/"parent_id":"(\w+)"/, assembled)
    id
  end
end
