defmodule Omunculus.Tools.ProposeConfigTest do
  use ExUnit.Case, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Tools.ProposeConfig

  defp project do
    dir = Fixtures.tmp_dir()

    Fixtures.write_config(dir, """
    [agents.keeper]
    depth = 0
    text = "I keep the project."
    tools = ["propose_config", "end"]
    deny = ["fs.write"]
    human = ["configure"]
    """)

    Fixtures.config_path(dir)
  end

  defp propose(path, args, view \\ %{}),
    do: ProposeConfig.run(%{config_path: path, args: args, view: view})

  defp request(%{"ok" => true, "emit" => [%{"body" => body}]}), do: body

  defp applied(request) do
    [%{"args" => args}] = request["options"]["apply"]
    Jason.decode!(args["value"])
  end

  test "a proposal lays its keys over the file's item and keeps the keys it leaves out" do
    path = project()

    body =
      request(
        propose(path, %{
          "item" => "agents.keeper",
          "value" => %{"text" => "Shorter."},
          "reason" => "r"
        })
      )

    assert %{"text" => "Shorter.", "deny" => ["fs.write"], "tools" => ["propose_config", "end"]} =
             applied(body)
  end

  test "a list the proposal gives replaces the file's whole, a null removes the key" do
    path = project()

    body =
      request(
        propose(path, %{
          "item" => "agents.keeper",
          "value" => %{"deny" => ["lsp"], "human" => nil},
          "reason" => "r"
        })
      )

    value = applied(body)
    assert value["deny"] == ["lsp"]
    refute Map.has_key?(value, "human")
    assert value["text"] == "I keep the project."
  end

  test "a nested table changes key by key" do
    path = project()
    File.write!(path, File.read!(path) <> "\n[agents.keeper.overrides.done]\nthen = [\"end\"]\n")

    body =
      request(
        propose(path, %{
          "item" => "agents.keeper",
          "value" => %{"overrides" => %{"work" => %{"then" => []}}},
          "reason" => "r"
        })
      )

    assert %{"overrides" => %{"done" => %{"then" => ["end"]}, "work" => %{"then" => []}}} =
             applied(body)
  end

  test "the request shows the item as the config runs it, before and after" do
    path = project()

    body =
      request(
        propose(path, %{
          "item" => "agents.keeper",
          "value" => %{"deny" => ["lsp"]},
          "reason" => "why"
        })
      )

    assert body["reason"] =~ ~r/agents.keeper as it runs now:\n.*deny = \["fs.write"\]/s
    assert body["reason"] =~ ~r/agents.keeper as it would run:\n.*deny = \["lsp"\]/s
    assert body["reason"] =~ "text = \"I keep the project.\""
    assert body["reason"] =~ "runs cited: none"
  end

  test "a proposal that changes nothing is refused" do
    assert %{"ok" => false, "output" => output} =
             propose(project(), %{
               "item" => "agents.keeper",
               "value" => %{"deny" => ["fs.write"]},
               "reason" => "r"
             })

    assert output =~ "already holds"
  end

  test "a cited run must be one of the recent runs" do
    path = project()
    recent = [%{id: "abc123def", agent: "worker", work_title: "Menu"}]
    args = %{"item" => "agents.keeper", "value" => %{"text" => "x"}, "reason" => "r"}

    assert %{"ok" => false, "output" => output} =
             propose(path, Map.put(args, "runs", ["zzz"]), %{"recent" => recent})

    assert output =~ ~s(no run "zzz")

    body = request(propose(path, Map.put(args, "runs", ["abc123"]), %{"recent" => recent}))
    assert body["reason"] =~ "runs cited:\n- abc123def, worker, work Menu"
  end

  test "a change the person refused in the conversation is refused again" do
    path = project()
    args = %{"item" => "agents.keeper", "value" => %{"deny" => ["lsp"]}, "reason" => "r"}
    options = request(propose(path, args))["options"]

    refused = %{answer: "deny", reply: "no language server here", options: Jason.encode!(options)}

    assert %{"ok" => false, "output" => output} = propose(path, args, %{"answered" => [refused]})
    assert output =~ "already refused this change: no language server here"

    # Another change, or one that was applied, goes through.
    other = Map.put(args, "value", %{"deny" => ["fs.write", "lsp"]})
    assert %{"ok" => true} = propose(path, other, %{"answered" => [refused]})
    assert %{"ok" => true} = propose(path, args, %{"answered" => [%{refused | answer: "apply"}]})
  end
end
