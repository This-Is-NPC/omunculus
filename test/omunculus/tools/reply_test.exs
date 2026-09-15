defmodule Omunculus.Tools.ReplyTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Reply

  @input %{
    name: "reply",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "emits a reply with request_id, decision and body" do
    input = %{
      @input
      | args: %{"request_id" => "req_1", "decision" => "grant", "body" => "pode"}
    }

    assert Reply.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "reply",
                 "body" => %{"request_id" => "req_1", "decision" => "grant", "body" => "pode"}
               }
             ]
           }
  end

  test "scope is present only when given" do
    input = %{
      @input
      | args: %{
          "request_id" => "req_1",
          "decision" => "grant",
          "body" => "pode",
          "scope" => "agent"
        }
    }

    assert Reply.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "reply",
                 "body" => %{
                   "request_id" => "req_1",
                   "decision" => "grant",
                   "body" => "pode",
                   "scope" => "agent"
                 }
               }
             ]
           }
  end

  test "ignores a blank scope" do
    input = %{
      @input
      | args: %{"request_id" => "req_1", "decision" => "grant", "body" => "pode", "scope" => ""}
    }

    assert Reply.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "reply",
                 "body" => %{"request_id" => "req_1", "decision" => "grant", "body" => "pode"}
               }
             ]
           }
  end

  test "refuses without a request_id" do
    input = %{@input | args: %{"decision" => "grant", "body" => "pode"}}

    assert Reply.run(input) == %{
             "ok" => false,
             "output" => "request_id required",
             "emit" => []
           }
  end

  test "refuses without a decision" do
    input = %{@input | args: %{"request_id" => "req_1", "body" => "pode"}}

    assert Reply.run(input) == %{"ok" => false, "output" => "decision required", "emit" => []}
  end

  test "refuses without a body" do
    input = %{@input | args: %{"request_id" => "req_1", "decision" => "grant"}}

    assert Reply.run(input) == %{"ok" => false, "output" => "body required", "emit" => []}
  end

  test "the builtin catalog discovers reply with triggers cli and model" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"reply" => manifest} = catalog
    assert manifest.triggers == ["cli", "model"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "reply")
    input = %{@input | args: %{"request_id" => "req_1", "decision" => "deny", "body" => "não"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Reply.run(input)["emit"]
  end
end
