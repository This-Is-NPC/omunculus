defmodule Omunculus.Tools.AssembleTest do
  use ExUnit.Case, async: true

  alias Omunculus.Prompt
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

  # The prompt as the run stores it: the instructions, then the context.
  defp whole(input) do
    out = Assemble.run(input)
    Prompt.text(%Prompt{instructions: out["instructions"], context: out["output"]})
  end

  test "the context starts with where the run is: its workspace, the home and the platform" do
    out = Assemble.run(%{@input | roots: ["/srv/work"]})

    assert out["output"] =~
             ~r"^## Environment\nworkspace: /srv/work\nhome: #{System.user_home!()}\nplatform: "

    assert out["output"] =~ "Every command starts in the workspace"
    refute out["instructions"] =~ "## Environment"
    refute Assemble.run(@input)["output"] =~ "## Environment"
  end

  test "a run without a work is shown its conversation's works and what was said, newest within conversation_bytes" do
    said = fn reply -> %{type: "model", body: Jason.encode!(reply)} end

    view = %{
      "catalog" => [],
      "message" => %{body: "and the colours?"},
      "conversation_works" => [
        %{id: "w1", title: "Bakery site", state: "done", last_comment: %{body: "Published"}}
      ],
      "chat" => [
        %{message: %{body: "I want a site"}, events: [said.(%{"content" => "Which shop?"})]},
        %{
          message: %{body: "Doce Ana"},
          events: [
            said.(%{
              "content" => [
                %{"type" => "text", "text" => "Checking its works first."},
                %{"type" => "tool_use", "name" => "works"}
              ]
            }),
            said.(%{"content" => [%{"type" => "text", "text" => "Handing it down."}]})
          ]
        },
        %{
          message: %{body: "thanks"},
          events: [
            said.(%{
              "content" => "Nothing more to do.",
              "tool_calls" => [%{"function" => %{"name" => "end"}}]
            })
          ]
        }
      ]
    }

    output = Assemble.run(%{@input | view: view})["output"]

    assert output =~ "## Works\n- Bakery site (work w1, done): Published"

    assert output =~
             "## Conversation\n- person: I want a site\n- you: Which shop?\n- person: Doce Ana\n- you: Handing it down.\n- person: thanks\n"

    refute output =~ "Checking its works first."
    refute output =~ "Nothing more to do."

    cut = %{@input | view: view, args: Map.put(@input.args, "conversation_bytes", 70)}

    assert Assemble.run(cut)["output"] =~
             "## Conversation\n- person: Doce Ana\n- you: Handing it down.\n- person: thanks\n"
  end

  test "the instructions hold what stays across runs, the output the run's context" do
    view = fn work, message ->
      %{
        "work" => %{id: work, title: work, goal: "g"},
        "message" => %{body: message},
        "agents" => [%{name: "worker", tools: ["write"]}],
        "catalog" => [%{name: "work", description: "Hands work down.", tags: [], groups: []}]
      }
    end

    first = Assemble.run(%{@input | view: view.("A", "one")})
    second = Assemble.run(%{@input | view: view.("B", "two")})

    assert first["instructions"] == second["instructions"]
    assert first["instructions"] =~ "You are the concierge.\n\n## Agents\n- worker: also write"
    refute first["instructions"] =~ "## Work"
    assert first["output"] =~ "## Work\nA"
    assert first["output"] =~ "## Message\none"
    refute first["output"] =~ "concierge"
  end

  test "joins agent text, message and every catalog card" do
    view = %{
      "message" => %{body: "count to 5"},
      "catalog" => [
        %{
          name: "break",
          description: "Stops the stage.",
          tags: ["sequence", "work"],
          groups: ["sequence"]
        }
      ]
    }

    output = whole(%{@input | view: view})
    assert output =~ "You are the concierge."
    assert output =~ "## Message\ncount to 5"
    assert output =~ Out.tools_preamble()
    assert output =~ "- break: Stops the stage. [tags: sequence, work]"
  end

  test "the files attached in the conversation come before the message" do
    file = %{
      "name" => "notes.txt",
      "media_type" => "text/plain",
      "bytes" => 5,
      "sha256" => "2cf2",
      "by" => "person"
    }

    output =
      whole(%{@input | view: %{"message" => %{body: "see the notes"}, "attachments" => [file]}})

    assert output =~
             "## Attachments\n- notes.txt (text/plain, 5 bytes) from person, sha256 2cf2\n\n## Message\nsee the notes"
  end

  test "with the work card, each agent comes with the tools it has that this run has not" do
    cards =
      for name <- ["work", "read"],
          do: %{name: name, description: name, tags: [], groups: [], pinned: true}

    view = %{
      "catalog" => cards,
      "agents" => [
        %{name: "worker", tools: ["read", "write", "edit"]},
        %{name: "reader", tools: ["read"]}
      ]
    }

    output = whole(%{@input | view: view})
    assert output =~ "## Agents\n- worker: also write, edit\n- reader\n\n## Tools"
  end

  test "results list each closed child with its report, and the report of a child that broke" do
    view = %{
      "results" => [
        %{
          id: "w1",
          title: "Answer",
          assignee: "worker",
          state: "done",
          last_comment: %{body: "said hi"}
        },
        %{id: "w2", title: "Skip", assignee: "worker", state: "cancelled", last_comment: nil}
      ],
      "cause" => %{
        type: "break",
        actor_id: "worker",
        work_id: "w3",
        body: ~s({"body":"no access"})
      }
    }

    output = whole(%{@input | view: view})

    assert output =~
             "## Results\n- Answer (worker, done, work w1): said hi\n- Skip (worker, cancelled, work w2)\n- worker broke its work w3: no access"
  end

  test "children list every work handed down as it stands, one that broke waiting on the run" do
    child = fn attrs ->
      Map.merge(
        %{workflow: nil, stage: nil, waiting: nil, last_comment: nil, assignee: "worker"},
        attrs
      )
    end

    view = %{
      "children" => [
        child.(%{id: "w1", title: "Build", state: "done"}),
        child.(%{id: "w2", title: "Plan", state: "waiting", waiting: "child"}),
        child.(%{
          id: "w3",
          title: "Publish",
          assignee: "publisher",
          state: "waiting",
          workflow: "design",
          stage: "publish",
          last_comment: %{body: "deploy failed"}
        })
      ]
    }

    assert whole(%{@input | view: view}) =~
             "## Children\n- Build (worker, work w1): done\n" <>
               "- Plan (worker, work w2): waiting on its own works\n" <>
               "- Publish (publisher, work w3, workflow design, stage publish): " <>
               "broke, waiting on you to reopen it or to break this work: deploy failed"
  end

  test "no results, no section" do
    output = Assemble.run(%{@input | view: %{"results" => [], "cause" => %{type: "continue"}}})
    refute output["output"] =~ "## Results"
  end

  test "without pinned every catalog card is listed even past 12" do
    cards =
      for i <- 1..13 do
        name = if i == 1, do: "tool_search", else: "t#{i}"
        %{name: name, description: name, tags: [], groups: [], pinned: true}
      end

    output = whole(%{@input | view: %{"catalog" => cards}})
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

    output = whole(%{@input | view: %{"catalog" => cards}})
    assert output =~ "- tool_search:"
    assert output =~ "- comment:"
    refute output =~ "- read:"
    assert output =~ Out.more_tools(1)
  end

  test "cards without tags have no [tags:] suffix" do
    cards = [%{name: "break", description: "Stops the stage.", tags: [], groups: ["sequence"]}]
    output = whole(%{@input | view: %{"catalog" => cards}})
    assert output =~ "- break: Stops the stage."
    refute output =~ "[tags:"
  end

  test "without tool_search, pinned is ignored and every card is listed" do
    cards = [
      %{name: "comment", description: "note", tags: [], groups: ["store"], pinned: true},
      %{name: "read", description: "read", tags: [], groups: ["fs.read"], pinned: false}
    ]

    output = whole(%{@input | view: %{"catalog" => cards}})
    assert output =~ "- comment:"
    assert output =~ "- read:"
    refute output =~ "more tools"
  end

  test "renders the work title, its id, its goal and the last comment, in that order" do
    view = %{
      "work" => %{id: "w9", title: "Fix the parser", goal: "the parser accepts trailing commas"},
      "comments" => [%{body: "first note"}, %{body: "last note"}],
      "catalog" => []
    }

    output = whole(%{@input | view: view})

    assert output =~
             "## Work\nFix the parser\nid: w9\n\n## Goal\nthe parser accepts trailing commas\n\n## Last comment\nlast note"

    refute output =~ "first note"

    staged =
      put_in(view, ["work"], Map.merge(view["work"], %{workflow: "sale", stage: "qualify"}))

    assert whole(%{@input | view: staged}) =~
             "## Work\nFix the parser\nid: w9\nworkflow: sale, stage: qualify\n"
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
      "work" => %{id: "w9", title: "Fix the parser", goal: "the parser accepts trailing commas"},
      "comments" => [%{body: "first note"}, %{body: "last note"}],
      "last_run" => %{message: %{body: "fix the parser"}, events: events},
      "catalog" => []
    }

    output = whole(%{@input | view: view})

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
      "last_run" => %{message: nil, events: [call.("abcdef"), call.("ab€"), call.("abc")]},
      "catalog" => []
    }

    args = Map.put(@input.args, "last_run_output_bytes", 3)
    output = whole(%{@input | args: args, view: view})

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

    assert whole(%{@input | view: view}) =~ "abcdef\n- tool read {} ok\nab€"
  end

  test "without a work, the last run is the one that opened the run's request" do
    view = %{
      "opener" => %{
        message: nil,
        events: [%{type: "model", body: "asked for write"}]
      },
      "catalog" => []
    }

    output = whole(%{@input | view: view})
    assert output =~ "## Last run\n- model asked for write"
  end

  test "inbox appears only when args carry inbox_id, and the sections go from what stays to what changes" do
    view = %{
      "message" => %{body: "hi"},
      "work" => %{id: "w9", title: "Fix the parser", goal: "the parser accepts trailing commas"},
      "comments" => [%{body: "last note"}],
      "request" => %{
        id: "req_1",
        requester: Jason.encode!(Omunculus.Participant.agent("worker")),
        status: "pending",
        options:
          ~s({"grant":[{"name":"grant","args":{"kind":"tool","name":"write"}}],"grant_agent":[{"name":"grant","args":{"kind":"tool","name":"write","scope":"agent"}}],"deny":[]})
      },
      "request_comments" => [%{body: "please look"}],
      "inbox_comments" => [%{body: "standalone notice"}],
      "inbox.work" => [%{body: "should not appear"}],
      "catalog" => []
    }

    without = whole(%{@input | view: view})
    refute without =~ "## Inbox"
    refute without =~ "should not appear"

    with_inbox =
      whole(%{
        @input
        | args: %{"text" => "You are the concierge.", "inbox_id" => "inb_1"},
          view: view
      })

    assert with_inbox =~ "## Inbox\ninb_1\nstandalone notice"

    assert with_inbox =~
             "## Request\nreq_1 requested by worker\n#{Out.answer_request()}\n- deny\n" <>
               ~s(- grant: grant {"kind":"tool","name":"write"}\nplease look)

    refute with_inbox =~ "should not appear"
    # Only a person may grant with a scope, so an agent is not offered it.
    refute with_inbox =~ "grant_agent"

    headers = ["Tools", "Work", "Goal", "Last comment", "Request", "Inbox", "Message"]
    at = Enum.map(headers, &(:binary.match(with_inbox, "## " <> &1) |> elem(0)))
    assert at == Enum.sort(at)
  end

  test "the builtin catalog discovers assemble with triggers == [\"harness\"]" do
    catalog = Catalog.unconfigured()
    assert %{"assemble" => manifest} = catalog
    assert manifest.triggers == ["harness"]
    assert Enum.any?(manifest.views, &(&1.key == "catalog" and &1.source == "catalog"))
  end

  test "an answered request shows its reply, not its options" do
    view = %{
      "request" => %{
        id: "req_1",
        requester: Jason.encode!(Omunculus.Participant.agent("worker")),
        status: "closed",
        answer: "grant",
        options: ~s({"grant":[{"name":"grant","args":{"kind":"tool","name":"write"}}],"deny":[]})
      },
      "request_comments" => [%{body: "granted, go on"}],
      "catalog" => []
    }

    assert whole(%{@input | view: view}) =~
             "## Request\nreq_1 requested by worker, answered grant: the reply is below\ngranted, go on"

    refute whole(%{@input | view: view}) =~ "- grant"
  end

  test "a closed text-only request shows its answer without an option label" do
    view = %{
      "request" => %{
        id: "req_1",
        requester: Jason.encode!(Omunculus.Participant.agent("worker")),
        status: "closed",
        answer: nil,
        options: "{}"
      },
      "request_comments" => [%{body: "Use the existing logo."}],
      "catalog" => []
    }

    assert whole(%{@input | view: view}) =~
             "## Request\nreq_1 requested by worker, answered: the reply is below\nUse the existing logo."
  end

  test "the manifest wiring yields the same output as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "assemble")
    assert {:ok, result} = Invoke.call(manifest, @input)
    assert result.output == Assemble.run(@input)["output"]
    assert result.instructions == Assemble.run(@input)["instructions"]
  end

  defp incoming(id, work, reason, requester \\ Omunculus.Participant.agent("worker")) do
    %{
      id: id,
      requester: Jason.encode!(requester),
      work_id: work,
      workflow: "client-work",
      stage: "design",
      status: "pending",
      reason: reason,
      options: Jason.encode!(%{"answer" => []}),
      origins: %{}
    }
  end

  test "the inbox combines a conversation's questions, preserves origins and shows its cause once" do
    first = incoming("logo", "design-work", "Which logo?")

    second =
      incoming("tone", "copy-work", "Which tone?", Omunculus.Participant.human("test", "client"))

    merged = %{
      incoming("merged", "lead-work", "Please answer the design questions.")
      | options: "{}",
        origins: %{"logo" => first, "tone" => second}
    }

    other = incoming("schedule", "schedule-work", "What is the opening date?")

    view = %{
      "inbox" => [%{conversation_id: "client-a", requests: [merged, other]}],
      "request" => merged,
      "request_comments" => [%{body: merged.reason}, %{body: "The existing logo is outdated."}],
      "inbox_comments" => [%{body: "Client sent the assets"}],
      "message" => %{body: "Here are the assets"}
    }

    out = Assemble.run(%{@input | view: view, args: Map.put(@input.args, "inbox_id", "notice")})
    text = out["output"]
    assert text =~ "## Inbox\n### Conversation client-a"

    for question <- [first, second, merged, other] do
      assert text =~ question.reason
      assert text =~ question.work_id
      assert length(String.split(text, question.id <> " requested by")) <= 2
    end

    assert text =~ "workflow client-work, stage design"
    assert text =~ "requested by test:client"
    assert text =~ "part logo: request logo"
    assert text =~ "part tone: request tone"
    assert text =~ "The existing logo is outdated."
    assert text =~ "notice\nClient sent the assets"
    assert length(String.split(text, "merged requested by")) == 2
    assert length(String.split(text, "## Inbox")) == 2
    refute text =~ "## Request\n"
    refute out["instructions"] =~ "Which logo?"
    assert :binary.match(text, "## Inbox") < :binary.match(text, "## Message")
  end

  test "received questions are included in the news of a continued session" do
    first = incoming("logo", "design-work", "Which logo?")
    second = incoming("tone", "copy-work", "Which tone?")
    original = Assemble.run(@input)["instructions"]
    model = %{"role" => "assistant", "content" => "Awaiting the client."}

    paused = %{
      id: "paused",
      agent: "concierge",
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      assembled: original <> "\n\n## Inbox\nEarlier question",
      events: [%{type: "model", body: Jason.encode!(model)}]
    }

    args =
      Map.merge(@input.args, %{
        "agent" => "concierge",
        "session_ttl_ms" => 60_000,
        "session_max_bytes" => 100_000
      })

    view = %{
      "catalog" => [],
      "session" => %{runs: [paused]},
      "inbox" => [%{conversation_id: "client-a", requests: [first, second]}]
    }

    out = Assemble.run(%{@input | args: args, view: view})
    assert out["session"]["continues"] == "paused"
    since = out["session"]["since"]
    assert since =~ "## Inbox\n### Conversation client-a"
    assert since =~ "Which logo?"
    assert since =~ "Which tone?"
    assert List.last(out["session"]["history"]) == %{"user" => since}
    assert out["instructions"] == original
  end
end
