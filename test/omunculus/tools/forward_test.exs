defmodule Omunculus.Tools.ForwardTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Forward

  @works [
    %{id: "w1", title: "Bakery site", state: "open"},
    %{id: "w2", title: "Logo", state: "done"}
  ]

  defp forward(work_id),
    do:
      Forward.run(%{
        args: %{"work_id" => work_id, "message" => "make the header pink"},
        view: %{"works" => @works}
      })

  test "hands the message to an open work of the conversation" do
    assert forward("w1") == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "prompt",
                 "body" => %{"work_id" => "w1", "message" => "make the header pink"}
               }
             ]
           }
  end

  test "refuses a closed work, or one not under ## Works" do
    assert %{"ok" => false, "output" => "work w2 is done" <> _} = forward("w2")
    assert %{"ok" => false, "output" => "no work w9 under ## Works"} = forward("w9")
  end

  test "the builtin catalog discovers forward, ending the run" do
    assert %{"forward" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["model"]
    assert manifest.then == ["end"]
  end
end
