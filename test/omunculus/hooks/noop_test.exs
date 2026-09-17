defmodule Omunculus.Hooks.NoopTest do
  use ExUnit.Case, async: true

  alias Omunculus.Hooks.Noop
  alias Omunculus.Tool.{Catalog, Invoke}

  @input %{
    name: "on-request",
    args: %{"type" => "request", "body" => %{}},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "run/1 always yields the no-op out" do
    assert Noop.run(@input) == %{"ok" => true, "output" => "", "emit" => []}
    assert Noop.run(%{}) == %{"ok" => true, "output" => "", "emit" => []}
  end

  for hook <- ~w(on-request on-notify on-continue on-break) do
    test "invoking the builtin #{hook} hook manifest yields the no-op out" do
      catalog = Catalog.unconfigured()
      manifest = Map.fetch!(catalog, unquote(hook))

      assert manifest.kind == "hook"
      assert manifest.triggers == []

      input = %{@input | name: unquote(hook)}
      assert {:ok, %{ok: true, output: "", emit: []}} = Invoke.call(manifest, input)
    end
  end
end
