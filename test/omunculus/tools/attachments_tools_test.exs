defmodule Omunculus.Tools.AttachmentsToolsTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Attachments, Config, ExecutionPolicyFixtures, Fixtures}
  alias Omunculus.Tools.{Attach, Out, ReadAttachment}

  setup do
    dir = Fixtures.tmp_dir()

    Fixtures.write_config(
      dir,
      "[agents.concierge]\ndepth = 0\ntext = \"c\"\n" <>
        ~s([store]\npath = "s.sqlite3"\nattachments = "files"\nattachment_bytes = 64\n)
    )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(root)
    {:ok, config} = Config.load(Fixtures.config_path(dir))
    %{config_path: Fixtures.config_path(dir), store: config.store, root: root}
  end

  defp attach(args, %{config_path: config_path, root: root}) do
    input = %{args: args, view: %{}, roots: [root], config_path: config_path}
    Attach.run(input, ExecutionPolicyFixtures.policy([root]))
  end

  test "attach keeps a workspace file and emits it with its note", %{root: root} = ctx do
    File.write!(Path.join(root, "report.csv"), "week,orders\n38,412\n")

    assert %{"ok" => true, "output" => "attached report.csv (19 bytes)", "emit" => [emit]} =
             attach(%{"path" => "report.csv", "note" => "the orders"}, ctx)

    assert %{"type" => "attach", "body" => %{"note" => "the orders", "attachments" => [meta]}} =
             emit

    assert %{"name" => "report.csv", "media_type" => "text/csv", "bytes" => 19} = meta
    assert {:ok, [^meta]} = Attachments.check(ctx.store, [meta])
  end

  test "attach refuses a path outside the roots and a file past attachment_bytes",
       %{root: root} = ctx do
    assert attach(%{"path" => "../omunculus.toml"}, ctx) ==
             Out.fail("path outside roots: ../omunculus.toml")

    File.write!(Path.join(root, "big.txt"), String.duplicate("x", 65))
    assert %{"ok" => false, "output" => output} = attach(%{"path" => "big.txt"}, ctx)
    assert output =~ "too_large"
  end

  test "read_attachment reads a file attached in the conversation, and only those", ctx do
    {:ok, text} = Attachments.put(ctx.store, "notes.txt", "text/plain", "hello")
    {:ok, binary} = Attachments.put(ctx.store, "call.wav", "audio/wav", <<82, 73, 70, 70, 228>>)
    view = %{"attachments" => [text, binary]}

    read = fn sha256 ->
      ReadAttachment.run(%{args: %{"sha256" => sha256}, view: view, config_path: ctx.config_path})
    end

    assert read.(text["sha256"]) == Out.ok("hello")
    assert read.(binary["sha256"]) == Out.fail(Out.not_text("call.wav", 5))

    {:ok, other} = Attachments.put(ctx.store, "other.txt", "text/plain", "elsewhere")

    assert read.(other["sha256"]) ==
             Out.fail("no file of sha256 #{other["sha256"]} is attached in this conversation")
  end
end
