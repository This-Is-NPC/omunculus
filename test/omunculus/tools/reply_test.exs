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

  test "an empty option chains nothing" do
    assert %{"chain" => []} = Reply.run(%{@input | args: %{@args | "option" => "deny"}})
  end

  test "an option the request lacks, or a request not found, chains nothing" do
    assert %{"ok" => true, "chain" => []} =
             Reply.run(%{@input | args: %{@args | "option" => "maybe"}})

    assert %{"ok" => true, "chain" => []} = Reply.run(%{@input | args: @args, view: %{}})
  end

  test "refuses without a request_id, an option or a body" do
    for key <- ["request_id", "option", "body"] do
      assert Reply.run(%{@input | args: Map.delete(@args, key)}) == %{
               "ok" => false,
               "output" => "#{key} required",
               "emit" => []
             }
    end
  end

  test "the builtin manifest reads the request view and chains grant and cancel" do
    assert %{"reply" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["cli", "model"]
    assert manifest.views == ["request"]
    assert manifest.chains == ["grant", "cancel"]
    assert manifest.then == []
  end

  test "the manifest wiring yields the same out as calling the module directly" do
    manifest = Map.fetch!(Catalog.unconfigured(), "reply")
    input = %{@input | args: @args}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Reply.run(input)["emit"]
    assert result.chain == [%{name: "grant", args: hd(Reply.run(input)["chain"])["args"]}]
  end
end
