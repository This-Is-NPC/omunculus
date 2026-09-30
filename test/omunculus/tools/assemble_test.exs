defmodule Omunculus.Tools.AssembleTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{Assemble, Out}

  @input %{
    name: "assemble",
    args: %{"text" => "You are the concierge."},
    view: %{"catalog" => []},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "joins agent text, message and every catalog card" do
    view = %{
      "prompt" => %{body: "count to 5"},
      "catalog" => [
        %{
          name: "break",
          description: "Stops the stage.",
          tags: ["sequence", "work"],
          groups: ["sequence"]
        }
      ]
    }

    output = Assemble.run(%{@input | view: view})["output"]
    assert output =~ "You are the concierge."
    assert output =~ "## Message\ncount to 5"
    assert output =~ Out.tools_preamble()
    assert output =~ "- break: Stops the stage. [tags: sequence, work]"
  end

  test "without pinned every catalog card is listed even past 12" do
    cards =
      for i <- 1..13 do
        name = if i == 1, do: "tool_search", else: "t#{i}"
        %{name: name, description: name, tags: [], groups: [], pinned: true}
      end

    output = Assemble.run(%{@input | view: %{"catalog" => cards}})["output"]
    assert output =~ "- tool_search:"
    assert output =~ "- t4:"
    assert output =~ "- t13:"
    refute output =~ Out.more_tools(1)
  end

  test "with tool_search, unpinned cards collapse behind more_tools" do
    cards = [
      %{name: "tool_search", description: "search", tags: [], groups: ["catalog"], pinned: true},
      %{name: "comment", description: "note", tags: [], groups: ["store"], pinned: true},
      %{name: "read", description: "read", tags: [], groups: ["fs.read"], pinned: false}
    ]

    output = Assemble.run(%{@input | view: %{"catalog" => cards}})["output"]
    assert output =~ "- tool_search:"
    assert output =~ "- comment:"
    refute output =~ "- read:"
    assert output =~ Out.more_tools(1)
  end

  test "cards without tags have no [tags:] suffix" do
    cards = [%{name: "break", description: "Stops the stage.", tags: [], groups: ["sequence"]}]
    output = Assemble.run(%{@input | view: %{"catalog" => cards}})["output"]
    assert output =~ "- break: Stops the stage."
    refute output =~ "[tags:"
  end

  test "without tool_search, pinned is ignored and every card is listed" do
    cards = [
      %{name: "comment", description: "note", tags: [], groups: ["store"], pinned: true},
      %{name: "read", description: "read", tags: [], groups: ["fs.read"], pinned: false}
    ]

    output = Assemble.run(%{@input | view: %{"catalog" => cards}})["output"]
    assert output =~ "- comment:"
    assert output =~ "- read:"
    refute output =~ "more tools"
  end

  test "renders the work title, its goal and the last comment, in that order" do
    view = %{
      "work" => %{title: "Fix the parser", goal: "the parser accepts trailing commas"},
      "comments.work" => [%{body: "first note"}, %{body: "last note"}],
      "catalog" => []
    }

    output = Assemble.run(%{@input | view: view})["output"]

    assert output =~
             "## Work\nFix the parser\n\n## Goal\nthe parser accepts trailing commas\n\n## Last comment\nlast note"

    refute output =~ "first note"
  end

  test "the last run lists every event but this tool's calls and the run's start and end" do
    call = fn body -> %{type: "tool", body: Jason.encode!(body)} end

    events = [
      %{type: "start-run", body: ~s({"agent":"worker"})},
      call.(%{name: "assemble", args: %{}, ok: true, output: "an earlier prompt"}),
      %{type: "model", body: ~s({"content":"reading","usage":{"prompt_tokens":3}})},
      call.(%{name: "read", args: %{path: "parser.ex"}, ok: true, output: "defmodule Parser"}),
      call.(%{name: "write", args: %{path: "parser.ex"}, ok: false, output: "not writable"}),
      call.(%{name: "comment", args: %{body: "halfway"}, ok: true, output: ""}),
      %{type: "comment", body: ~s({"body":"halfway"})},
      call.(%{name: "end", args: %{}, ok: true, output: "", via: "done"}),
      %{type: "end-run", body: "{}"}
    ]

    view = %{
      "work" => %{title: "Fix the parser", goal: "the parser accepts trailing commas"},
      "comments.work" => [%{body: "first note"}, %{body: "last note"}],
      "runs.last.work" => %{message: %{body: "fix the parser"}, events: events},
      "catalog" => []
    }

    output = Assemble.run(%{@input | view: view})["output"]

    assert String.ends_with?(
             output <> "\n",
             """
             ## Goal
             the parser accepts trailing commas

             ## Last comment
             last note

             ## Last run
             - message fix the parser
             - model {"content":"reading"}
             - tool read {"path":"parser.ex"} ok
             defmodule Parser
             - tool write {"path":"parser.ex"} failed
             not writable
             - tool comment {"body":"halfway"} ok
             - comment {"body":"halfway"}
             - tool end via done {} ok
             """
           )

    refute output =~ "an earlier prompt"
    refute output =~ "worker"
  end

  test "last_run_output_bytes cuts each call's output on a character boundary" do
    call = fn output ->
      %{type: "tool", body: Jason.encode!(%{name: "read", args: %{}, ok: true, output: output})}
    end

    view = %{
      "runs.last.work" => %{message: nil, events: [call.("abcdef"), call.("ab€"), call.("abc")]},
      "catalog" => []
    }

    args = Map.put(@input.args, "last_run_output_bytes", 3)
    output = Assemble.run(%{@input | args: args, view: view})["output"]

    assert output =~
             """
             - tool read {} ok
             abc
             #{Out.bytes_cut(3)}
             - tool read {} ok
             ab
             #{Out.bytes_cut(3)}
             - tool read {} ok
             abc\
             """

    assert Assemble.run(%{@input | view: view})["output"] =~ "abcdef\n- tool read {} ok\nab€"
  end

  test "without a work, the last run is the one that opened the run's request" do
    view = %{
      "runs.request" => %{
        message: nil,
        events: [%{type: "model", body: "asked for write"}]
      },
      "catalog" => []
    }

    output = Assemble.run(%{@input | view: view})["output"]
    assert output =~ "## Last run\n- model asked for write"
  end

  test "inbox appears only when args carry inbox_id, and the sections go from what stays to what changes" do
    view = %{
      "prompt" => %{body: "hi"},
      "work" => %{title: "Fix the parser", goal: "the parser accepts trailing commas"},
      "comments.work" => [%{body: "last note"}],
      "request" => %{
        id: "req_1",
        agent: "worker",
        options: ~s({"grant":[{"name":"grant","args":{"kind":"tool","name":"write"}}],"deny":[]})
      },
      "comments.request" => [%{body: "please look"}],
      "comments.inbox" => [%{body: "standalone notice"}],
      "inbox.work" => [%{body: "should not appear"}],
      "catalog" => []
    }

    without = Assemble.run(%{@input | view: view})["output"]
    refute without =~ "## Inbox"
    refute without =~ "should not appear"

    with_inbox =
      Assemble.run(%{
        @input
        | args: %{"text" => "You are the concierge.", "inbox_id" => "inb_1"},
          view: view
      })[
        "output"
      ]

    assert with_inbox =~ "## Inbox\ninb_1\nstandalone notice"

    assert with_inbox =~
             "## Request\nreq_1 requested by worker\n- deny\n" <>
               ~s(- grant: grant {"kind":"tool","name":"write"}\nplease look)

    refute with_inbox =~ "should not appear"

    headers = ["Tools", "Work", "Goal", "Last comment", "Request", "Inbox", "Message"]
    at = Enum.map(headers, &(:binary.match(with_inbox, "## " <> &1) |> elem(0)))
    assert at == Enum.sort(at)
  end

  test "the builtin catalog discovers assemble with triggers == [\"harness\"]" do
    catalog = Catalog.unconfigured()
    assert %{"assemble" => manifest} = catalog
    assert manifest.triggers == ["harness"]
    assert "catalog" in manifest.views
  end

  test "the manifest wiring yields the same output as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "assemble")
    assert {:ok, result} = Invoke.call(manifest, @input)
    assert result.output == Assemble.run(@input)["output"]
  end
end
