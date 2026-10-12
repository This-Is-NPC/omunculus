defmodule Omunculus.Tools.ReplyTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Reply

  @request %{
    id: "req_1",
    options:
      Jason.encode!(%{
        "grant" => [%{"name" => "grant", "args" => %{"kind" => "tool", "name" => "write"}}],
        "deny" => []
      })
  }

  @input %{
    name: "reply",
    args: %{},
    view: %{"request" => @request},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  @args %{"request_id" => "req_1", "option" => "grant", "body" => "go"}

  test "emits the reply and chains the option's calls with the request_id" do
    assert Reply.run(%{@input | args: @args}) == %{
             "ok" => true,
             "output" => "",
             "emit" => [%{"type" => "reply", "body" => @args}],
             "chain" => [
               %{
                 "name" => "grant",
                 "args" => %{"kind" => "tool", "name" => "write", "request_id" => "req_1"}
               }
             ]
           }
  end

  test "a missing, null or empty option answers with text and chains no effects" do
    expected = Map.delete(@args, "option")

    for args <- [expected, Map.put(@args, "option", nil), Map.put(@args, "option", "")] do
      assert %{
               "ok" => true,
               "emit" => [%{"type" => "reply", "body" => ^expected}],
               "chain" => []
             } = Reply.run(%{@input | args: args})
    end
  end

  test "an empty option chains nothing" do
    assert %{"chain" => []} = Reply.run(%{@input | args: %{@args | "option" => "deny"}})
  end

  test "an unknown option fails before calls chain; a missing request chains nothing" do
    assert %{"ok" => true, "chain" => []} =
             Reply.run(%{@input | args: %{@args | "option" => "maybe"}})

    assert %{"ok" => true, "chain" => []} = Reply.run(%{@input | args: @args, view: %{}})
  end

  test "refuses without a request_id or a body" do
    for key <- ["request_id", "body"] do
      assert Reply.run(%{@input | args: Map.delete(@args, key)}) == %{
               "ok" => false,
               "output" => "#{key} required",
               "emit" => []
             }
    end
  end

  test "the builtin manifest reads the request view and chains grant, cancel, configure and pack" do
    assert %{"reply" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["cli", "model"]
    assert Enum.map(manifest.views, &{&1.key, &1.source}) == [{"request", "requests"}]
    assert manifest.chains == ["grant", "cancel", "configure", "pack"]
    assert manifest.then == []
    assert manifest.parameters["required"] == ["body", "request_id"]
  end

  test "the manifest wiring yields the same out as calling the module directly" do
    manifest = Map.fetch!(Catalog.unconfigured(), "reply")
    input = %{@input | args: @args}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Reply.run(input)["emit"]
    assert result.chain == [%{name: "grant", args: hd(Reply.run(input)["chain"])["args"]}]
  end

  test "named parts recursively chain the original IDs and normalize empty options" do
    middle = %{id: "merged", options: "{}", origins: %{"leaf" => @request}}
    upstream = %{id: "upstream", options: "{}", origins: %{"design" => middle}}

    args = %{
      "request_id" => "upstream",
      "body" => "Answers",
      "parts" => %{
        "design" => %{
          "body" => "Design",
          "option" => nil,
          "parts" => %{
            "leaf" => %{"body" => "Granted", "option" => "grant"}
          }
        }
      }
    }

    assert %{"ok" => true, "chain" => [%{"args" => %{"request_id" => "req_1"}}], "emit" => [emit]} =
             Reply.run(%{@input | args: args, view: %{"request" => upstream}})

    refute Map.has_key?(emit["body"]["parts"]["design"], "option")
  end

  test "invalid named parts chain no calls and leave refusal to the store" do
    request = %{id: "upstream", options: "{}", origins: %{"design" => @request}}

    for parts <- [
          %{"unknown" => %{"body" => "x"}},
          %{"design" => %{"body" => "x", "request_id" => "spoof"}},
          %{"design" => %{"body" => ""}},
          %{"design" => %{"body" => "x", "option" => "unknown"}}
        ] do
      args = %{"request_id" => "upstream", "body" => "Answers", "parts" => parts}

      assert %{"ok" => true, "chain" => []} =
               Reply.run(%{@input | args: args, view: %{"request" => request}})
    end
  end

  test "an agent cannot select a sealed or permanent grant through an upstream part" do
    for args <- [
          %{"kind" => "tool", "name" => "deploy"},
          %{"kind" => "tool", "name" => "write", "scope" => "agent"}
        ] do
      leaf =
        %{@request | options: Jason.encode!(%{"grant" => [%{"name" => "grant", "args" => args}]})}
        |> Map.put(
          :requester_ceiling,
          Jason.encode!(%{
            have: [],
            askable: ["write"],
            sealed: ["deploy"],
            blocked: [],
            uncited: "askable"
          })
        )

      upstream = %{id: "upstream", options: "{}", origins: %{"design" => leaf}}

      answer = %{
        "request_id" => "upstream",
        "body" => "Answers",
        "parts" => %{"design" => %{"body" => "Yes", "option" => "grant"}}
      }

      input = %{@input | args: answer, view: %{"request" => upstream}, run_id: "agent_run"}
      assert %{"ok" => false, "emit" => []} = Reply.run(input)
      assert %{"ok" => true, "chain" => [_]} = Reply.run(%{input | run_id: nil})
    end
  end

  test "closed or invalid upstream replies cannot chain otherwise valid named effects" do
    upstream = %{
      id: "upstream",
      options: "{}",
      origins: %{"design" => @request},
      status: "pending"
    }

    args = %{
      "request_id" => "upstream",
      "body" => "Answer",
      "parts" => %{"design" => %{"body" => "Yes", "option" => "grant"}}
    }

    for {request, answer} <- [
          {%{upstream | status: "closed"}, args},
          {upstream, Map.put(args, "option", "unknown")}
        ] do
      assert %{"ok" => true, "chain" => []} =
               Reply.run(%{@input | args: answer, view: %{"request" => request}})
    end
  end
end
