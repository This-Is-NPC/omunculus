defmodule Omunculus.AgentTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Agent, Chat, FS, Tools}

  test "halts on assistant text with no tool calls" do
    chat =
      Chat.Fake.new([
        %{
          content: Jason.encode!(%{completed: true, comment: "done"}),
          tool_calls: nil,
          usage: %{"total_tokens" => 3}
        }
      ])

    fs = FS.Memory.new(%{"lib/a.ex" => "defmodule A, do: :ok\n"})

    assert {:ok, result} =
             Agent.run(
               instruction: "summarize",
               chat: chat,
               fs: fs,
               tools: ["read"],
               max_turns: 4
             )

    assert Jason.decode!(result.assistant_text)["comment"] == "done"
    assert result.turns == 1
  end

  test "request_permission adds schema when flag set" do
    chat =
      Chat.Fake.new([
        %{
          content: Jason.encode!(%{completed: true, comment: "done"}),
          tool_calls: nil,
          usage: %{"total_tokens" => 3}
        }
      ])

    fs = FS.Memory.new(%{})

    assert {:ok, result} =
             Agent.run(
               instruction: "ask",
               chat: chat,
               fs: fs,
               tools: [],
               request_permission: true,
               max_turns: 4
             )

    names =
      Enum.map(result.schemas, fn schema ->
        get_in(schema, ["function", "name"])
      end)

    assert "request_permission" in names
  end

  test "dispatches a write then halts" do
    chat =
      Chat.Fake.new([
        %{
          content: nil,
          tool_calls: [
            %{
              "id" => "call_1",
              "function" => %{
                "name" => "write",
                "arguments" => Jason.encode!(%{"path" => "README.md", "content" => "hello\n"})
              }
            }
          ],
          usage: nil
        },
        %{
          content: Jason.encode!(%{completed: true, comment: "wrote README"}),
          tool_calls: nil,
          usage: nil
        }
      ])

    fs = FS.Memory.new(%{})

    assert {:ok, result} =
             Agent.run(
               instruction: "add a README",
               chat: chat,
               fs: fs,
               tools: Tools.default_names(),
               max_turns: 8
             )

    assert Jason.decode!(result.assistant_text)["comment"] == "wrote README"
    assert result.fs.files["README.md"] == "hello\n"
    assert result.turns == 2
  end

  test "a tool outside the active set is denied without mutating the fs" do
    chat =
      Chat.Fake.new([
        %{
          content: nil,
          tool_calls: [
            %{
              "id" => "call_1",
              "function" => %{
                "name" => "write",
                "arguments" => Jason.encode!(%{"path" => "x", "content" => "nope"})
              }
            }
          ],
          usage: nil
        },
        %{
          content: Jason.encode!(%{completed: true, comment: "could not write"}),
          tool_calls: nil,
          usage: nil
        }
      ])

    fs = FS.Memory.new(%{})

    assert {:ok, result} =
             Agent.run(
               instruction: "write x",
               chat: chat,
               fs: fs,
               tools: ["read", "grep", "find", "ls"],
               max_turns: 8
             )

    refute Map.has_key?(result.fs.files, "x")
    assert Jason.decode!(result.assistant_text)["comment"] == "could not write"
  end

  test "edit replaces unique oldText against the original file" do
    chat =
      Chat.Fake.new([
        %{
          content: nil,
          tool_calls: [
            %{
              "id" => "call_1",
              "function" => %{
                "name" => "edit",
                "arguments" =>
                  Jason.encode!(%{
                    "path" => "lib/a.ex",
                    "edits" => [%{"oldText" => ":ok", "newText" => ":edited"}]
                  })
              }
            }
          ],
          usage: nil
        },
        %{
          content: Jason.encode!(%{completed: true, comment: "patched"}),
          tool_calls: nil,
          usage: nil
        }
      ])

    fs = FS.Memory.new(%{"lib/a.ex" => "defmodule A, do: :ok\n"})

    assert {:ok, result} =
             Agent.run(instruction: "patch", chat: chat, fs: fs, max_turns: 8)

    assert result.fs.files["lib/a.ex"] == "defmodule A, do: :edited\n"
  end

  test "counter tools do not impose a semantic success gate" do
    chat = Chat.Fake.new([Chat.Fake.report("Claimed done without counting")])

    assert {:ok, result} =
             Agent.run(
               instruction: "count to 2",
               chat: chat,
               fs: FS.Memory.new(),
               tools: ["counter"]
             )

    assert result.tool_calls == 0
    assert result.turns == 1
  end

  test "messages opt supplies starting conversation" do
    starting = [
      %{"role" => "system", "content" => "custom system"},
      %{"role" => "user", "content" => "prior user turn"}
    ]

    chat =
      Chat.Fake.new([
        %{
          content: Jason.encode!(%{completed: true, comment: "done"}),
          tool_calls: nil,
          usage: %{"total_tokens" => 1}
        }
      ])

    fs = FS.Memory.new(%{})

    assert {:ok, result} =
             Agent.run(
               instruction: "ignored when messages are provided",
               chat: chat,
               fs: fs,
               tools: ["read"],
               messages: starting,
               max_turns: 4
             )

    assert result.messages ==
             starting ++
               [
                 %{
                   "role" => "assistant",
                   "content" => Jason.encode!(%{completed: true, comment: "done"})
                 }
               ]
  end

  test "tool executor wait halts with assistant tool_calls and no tool messages" do
    tool_call = %{
      "id" => "call_wait",
      "function" => %{
        "name" => "read",
        "arguments" => Jason.encode!(%{"path" => "lib/a.ex"})
      }
    }

    chat =
      Chat.Fake.new([
        %{content: nil, tool_calls: [tool_call], usage: %{"total_tokens" => 2}}
      ])

    starting = [
      %{"role" => "system", "content" => "sys"},
      %{"role" => "user", "content" => "read the file"}
    ]

    executor = fn _name, _args, context, _tools ->
      {:wait, "paused", context}
    end

    fs = FS.Memory.new(%{"lib/a.ex" => "hello\n"})

    assert {:waiting, result} =
             Agent.run(
               instruction: "read",
               chat: chat,
               fs: fs,
               tools: ["read"],
               messages: starting,
               tool_executor: executor,
               max_turns: 4
             )

    assistant = List.last(result.messages)

    assert assistant["role"] == "assistant"
    assert assistant["tool_calls"] == [tool_call]
    refute Enum.any?(result.messages, &(&1["role"] == "tool"))
    assert result.messages == starting ++ [assistant]
    assert result.turns == 1
    assert result.tool_calls == 1
  end

  test "format repair cannot execute tools after reporting existing effects" do
    chat =
      Chat.Fake.new([
        Chat.Fake.tool_call("counter", %{}),
        Chat.Fake.text("The effect is complete"),
        Chat.Fake.tool_call("counter", %{}),
        Chat.Fake.report("One confirmed increment")
      ])

    assert {:ok, result} =
             Agent.run(
               instruction: "Increment once",
               chat: chat,
               fs: FS.Memory.new(),
               tools: ["counter"],
               max_turns: 5
             )

    assert result.tool_state["counter"].value == 1

    assert Enum.any?(
             result.messages,
             &String.contains?(&1["content"] || "", "report_format_only")
           )
  end
end
