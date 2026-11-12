defmodule Omunculus.Tools.MemoryToolsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.{Assemble, Forget, Recall, Remember}

  defp entry(id, scope, kind, text, at) do
    %{
      "id" => id,
      "scope" => scope,
      "kind" => kind,
      "text" => text,
      "at" => at,
      "by" => "seller",
      "conversation_id" => "c1"
    }
  end

  defp entries,
    do: [
      entry("m1", "project", "preference", "The client prefers short answers", "2026-01-01"),
      entry("m2", "workspace", "procedure", "Tests run with mix test in the repo", "2026-01-02"),
      entry("m3", "agent", "pitfall", "Deploys fail unless the cache is cold", "2026-01-03")
    ]

  describe "remember" do
    test "emits a memory action with the trimmed text" do
      args = %{"scope" => "project", "kind" => "fact", "text" => " the repo is a monorepo "}

      assert %{"ok" => true, "output" => "remembered", "emit" => [emit]} =
               Remember.run(%{args: args, view: %{"memories" => entries()}})

      assert emit == %{
               "type" => "memory",
               "body" => %{
                 "op" => "remember",
                 "scope" => "project",
                 "kind" => "fact",
                 "text" => "the repo is a monorepo"
               }
             }
    end

    test "emits nothing for text already kept in that scope and kind" do
      args = %{
        "scope" => "agent",
        "kind" => "pitfall",
        "text" => "deploys fail unless the cache is cold"
      }

      assert %{"ok" => true, "output" => "already remembered as m3", "emit" => []} =
               Remember.run(%{args: args, view: %{"memories" => entries()}})
    end

    test "needs scope, kind and text" do
      assert %{"ok" => false, "output" => "kind required"} =
               Remember.run(%{args: %{"scope" => "project", "text" => "x"}, view: %{}})
    end
  end

  describe "recall" do
    defp recall(args), do: Recall.run(%{args: args, view: %{"memories" => entries()}})

    test "matches the words of the query, the better match first" do
      out = recall(%{"query" => "tests deploys cache"})["output"]
      assert [first, second] = String.split(out, "\n")
      assert first =~ "m3"
      assert second =~ "m2"
      refute out =~ "m1"
    end

    test "narrows by scope and kind, newest first without a query" do
      assert recall(%{"scope" => "workspace"})["output"] =~ "m2"
      refute recall(%{"scope" => "workspace"})["output"] =~ "m1"
      assert [first | _] = String.split(recall(%{})["output"], "\n")
      assert first =~ "m3"
      assert recall(%{"kind" => "preference"})["output"] =~ "short answers"
      assert recall(%{"query" => "kubernetes"})["output"] == "nothing remembered"
    end

    test "gives the source and keeps to the limit" do
      assert recall(%{"limit" => 1})["output"] =~
               "- m3 [agent, pitfall] Deploys fail unless the cache is cold (by seller, 2026-01-03, conversation c1)"
    end
  end

  test "forget emits a memory action for the id" do
    assert %{"ok" => true, "emit" => [%{"type" => "memory", "body" => body}]} =
             Forget.run(%{args: %{"id" => "m1"}})

    assert body == %{"op" => "forget", "id" => "m1"}
    assert %{"ok" => false} = Forget.run(%{args: %{}})
  end

  describe "assemble" do
    defp input,
      do: %{
        name: "assemble",
        args: %{"text" => "You are the concierge."},
        view: %{"catalog" => [], "memories" => entries()},
        run_id: nil,
        work_id: nil,
        workspace: nil,
        roots: []
      }

    test "shows memory in the context only with memory_bytes, newest within it" do
      assert Assemble.run(input())["output"] == ""

      all = Assemble.run(%{input() | args: Map.put(input().args, "memory_bytes", 4096)})
      assert all["output"] =~ "## Memory\n"
      assert all["output"] =~ "- [agent, pitfall] Deploys fail unless the cache is cold"
      refute all["instructions"] =~ "Memory"

      cut = Assemble.run(%{input() | args: Map.put(input().args, "memory_bytes", 60)})
      assert cut["output"] =~ "Deploys fail"
      refute cut["output"] =~ "short answers"
    end
  end
end
