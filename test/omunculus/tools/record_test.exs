defmodule Omunculus.Tools.RecordTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.Record

  test "said is the text of a reply in each provider's shape" do
    assert Record.said(~s({"role":"assistant","content":"plain"})) == "plain"

    assert Record.said(%{
             "content" => [
               %{"type" => "text", "text" => "one"},
               %{"type" => "tool_use", "name" => "end"},
               %{"type" => "text", "text" => "two"}
             ]
           }) == "one\ntwo"

    assert Record.said(%{
             "output" => [
               %{
                 "type" => "message",
                 "content" => [%{"type" => "output_text", "text" => "said"}]
               },
               %{"type" => "function_call", "name" => "end"}
             ]
           }) == "said"

    assert Record.said("not json") == ""
  end

  test "a reply's answer is its text only when it calls no tool" do
    assert Record.answer(~s({"role":"assistant","content":"plain"})) == "plain"

    noting = %{
      "content" => "The question is already out.",
      "tool_calls" => [%{"function" => %{"name" => "end"}}]
    }

    assert Record.calls(noting) == ["end"]
    assert Record.answer(noting) == ""

    assert Record.calls(%{
             "content" => [
               %{"type" => "text", "text" => "Asking."},
               %{"type" => "tool_use", "name" => "ask"}
             ]
           }) == ["ask"]

    assert Record.calls(%{"output" => [%{"type" => "function_call", "name" => "work"}]}) ==
             ["work"]

    assert Record.answer("not json") == ""
  end
end
