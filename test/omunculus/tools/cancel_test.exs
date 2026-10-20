defmodule Omunculus.Tools.CancelTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.{Cancel, Out}

  test "emits cancel with the request_id" do
    assert Cancel.run(%{args: %{"request_id" => "req_1"}}) ==
             Out.ok("", [%{"type" => "cancel", "body" => %{"request_id" => "req_1"}}])

    assert Cancel.run(%{args: %{}}) == Out.fail("request_id required")
  end

  test "the builtin manifest is chain-only, in the sequence group" do
    assert %{triggers: ["chain"], groups: ["sequence"]} =
             Map.fetch!(Catalog.unconfigured(), "cancel")
  end
end
