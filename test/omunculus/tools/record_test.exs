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
end
