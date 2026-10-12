defmodule Omunculus.Tools.EscalateTest do
  use ExUnit.Case, async: true
  alias Omunculus.Tools.Escalate

  test "the model form emits named origins and its manifest ends the run" do
    args = %{"reason" => "Choose both", "origins" => %{"logo" => "r1", "tone" => "r2"}}

    assert %{"ok" => true, "emit" => [%{"type" => "escalate", "body" => ^args}]} =
             Escalate.run(%{args: args})

    manifest = Omunculus.Tool.Catalog.unconfigured()["escalate"]
    assert manifest.triggers == ["model"]
    assert manifest.then == ["end"]

    for invalid <- [nil, %{}, [], "invalid"] do
      assert %{"ok" => false, "emit" => []} =
               Escalate.run(%{args: %{args | "origins" => invalid}})
    end
  end
end
