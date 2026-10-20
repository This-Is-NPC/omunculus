defmodule Omunculus.Tools.GrantTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.{Grant, Out}

  @args %{"request_id" => "req_1", "name" => "write", "kind" => "tool"}

  test "emits grant with the request_id, name, kind and a scope only when given" do
    assert Grant.run(%{args: @args}) == Out.ok("", [grant(@args)])

    assert Grant.run(%{args: Map.put(@args, "scope", "agent")}) ==
             Out.ok("", [grant(Map.put(@args, "scope", "agent"))])

    assert Grant.run(%{args: Map.put(@args, "scope", "")}) ==
             Out.ok("", [grant(@args)])
  end

  test "refuses without a request_id, a name or a kind" do
    for key <- ["request_id", "name", "kind"] do
      assert Grant.run(%{args: Map.delete(@args, key)}) ==
               Out.fail("#{key} required")
    end
  end

  test "the builtin manifest is chain-only, in the store group" do
    assert %{"grant" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["chain"]
    assert manifest.groups == ["store"]
  end

  defp grant(body), do: %{"type" => "grant", "body" => body}
end
