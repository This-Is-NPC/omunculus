defmodule Omunculus.Tools.ReopenTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.Reopen

  @args %{"work_id" => "w1", "instructions" => "use edit this time"}

  test "emits reopen with the instructions, the agent and what to grant" do
    grant = [
      %{"kind" => "tool", "name" => "edit"},
      %{"kind" => "resource", "name" => "sandbox.write"}
    ]

    assert Reopen.run(%{args: Map.merge(@args, %{"agent" => "edward", "grant" => grant})}) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "reopen",
                 "body" => %{
                   "work_id" => "w1",
                   "body" => "use edit this time",
                   "agent" => "edward",
                   "grant" => grant
                 }
               }
             ]
           }
  end

  test "refuses a grant it cannot read" do
    for {grant, output} <- [
          {"edit", "grant must be a list of {kind, name}"},
          {[%{"name" => "edit"}], "each grant needs a kind and a name"},
          {[%{"kind" => "secret", "name" => "vault"}], "each grant needs a kind and a name"}
        ] do
      assert Reopen.run(%{args: Map.put(@args, "grant", grant)}) ==
               %{"ok" => false, "output" => output, "emit" => []}
    end
  end
end
