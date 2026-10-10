defmodule Omunculus.Tools.ChangesTest do
  use ExUnit.Case, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Tools.Changes

  @files [%{"path" => "a.md", "op" => "M", "added" => 2, "deleted" => 1}]

  defp config(store) do
    dir = Fixtures.tmp_dir()
    Fixtures.write_config(dir, "[agents.concierge]\ndepth = 0\ntext = \"c\"\n" <> store)
    Fixtures.config_path(dir)
  end

  defp tool(body), do: %{type: "tool", body: Jason.encode!(body)}

  defp input(config_path, args, view),
    do: %{args: args, view: view, config_path: config_path}

  test "a work below lists, call by call, the files its runs changed" do
    work = %{
      runs: [
        %{
          agent: "edward",
          events: [
            tool(%{"name" => "read"}),
            tool(%{"name" => "edit", "changes" => %{"files" => @files}})
          ]
        }
      ]
    }

    path = config(~s([store]\npath = "s.sqlite3"\nchanges = "changes"\n))

    assert Changes.run(input(path, %{"work_id" => "w2"}, %{"target" => work})) ==
             %{"ok" => true, "output" => "- edit (edward)\n  M a.md (+2 -1)", "emit" => []}

    assert %{"ok" => false, "output" => "work_id must name a work below this run's"} =
             Changes.run(input(path, %{"work_id" => "elsewhere"}, %{}))

    assert %{"output" => "No call changed a file."} = Changes.run(input(path, %{}, %{}))
  end

  test "without [store] changes nothing is recorded" do
    assert %{"ok" => false, "output" => "changes are not recorded: [store] changes is not set"} =
             Changes.run(input(config(""), %{}, %{}))
  end
end
