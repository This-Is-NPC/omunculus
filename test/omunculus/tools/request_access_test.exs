defmodule Omunculus.Tools.RequestAccessTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.RequestAccess

  @input %{
    name: "request_access",
    args: %{},
    view: %{"grant_scopes" => ["agent", "workspace"]},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  @permanent %{
    "grant_agent" => [
      %{"name" => "grant", "args" => %{"kind" => "tool", "name" => "write", "scope" => "agent"}}
    ],
    "grant_workspace" => [
      %{
        "name" => "grant",
        "args" => %{"kind" => "tool", "name" => "write", "scope" => "workspace"}
      }
    ],
    "deny" => []
  }

  @on_work Map.put(@permanent, "grant", [
             %{"name" => "grant", "args" => %{"kind" => "tool", "name" => "write"}}
           ])

  defp args(access),
    do: %{"report" => "blocked on access", "access" => access, "reason" => "need to write"}

  @write [%{"kind" => "tool", "name" => "write"}]

  test "without a work, emits a request with the reason, one grant per scope of the view, and deny" do
    assert RequestAccess.run(%{@input | args: args(@write)}) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "request",
                 "body" => %{"reason" => "need to write", "options" => @permanent}
               }
             ]
           }
  end

  test "in a run with a work, comments the report on it before a request that also grants on it" do
    assert RequestAccess.run(%{@input | work_id: "w1", args: args(@write)})["emit"] == [
             %{
               "type" => "comment",
               "body" => %{"work_id" => "w1", "body" => "blocked on access"}
             },
             %{
               "type" => "request",
               "body" => %{"reason" => "need to write", "options" => @on_work}
             }
           ]
  end

  test "each option grants everything asked, tools and sandbox capabilities alike" do
    access = @write ++ [%{"kind" => "resource", "name" => "sandbox.write"}]

    [%{"body" => %{"options" => options}}] =
      RequestAccess.run(%{@input | args: args(access)})["emit"]

    assert options["grant_agent"] == [
             %{
               "name" => "grant",
               "args" => %{"kind" => "tool", "name" => "write", "scope" => "agent"}
             },
             %{
               "name" => "grant",
               "args" => %{"kind" => "resource", "name" => "sandbox.write", "scope" => "agent"}
             }
           ]

    assert options["deny"] == []
  end

  test "permission requests can name a logical route without selecting a participant type" do
    args = Map.put(args(@write), "to", "release-approval")

    assert [%{"body" => %{"to" => "release-approval", "options" => @permanent}}] =
             RequestAccess.run(%{@input | args: args})["emit"]
  end

  test "refuses what it cannot ask for" do
    for {access, output} <- [
          {nil, "access required: a list of {kind, name}"},
          {[], "access required: a list of {kind, name}"},
          {[%{"kind" => "secret", "name" => "vault"}], "unsupported access kind: secret"},
          {[%{"kind" => "resource", "name" => "sandbox.shell"}],
           "unsupported resource: sandbox.shell"},
          {[%{"kind" => "tool"}], "each access needs a kind and a name"},
          {[%{"kind" => "tool", "name" => ""}], "each access needs a kind and a name"},
          {@write ++ [%{"name" => "edit"}], "each access needs a kind and a name"}
        ] do
      assert RequestAccess.run(%{@input | args: args(access)}) ==
               %{"ok" => false, "output" => output, "emit" => []},
             inspect(access)
    end
  end

  test "refuses without a report or a reason" do
    for key <- ~w(report reason) do
      assert RequestAccess.run(%{@input | args: Map.delete(args(@write), key)}) ==
               %{"ok" => false, "output" => "#{key} required", "emit" => []}
    end
  end

  test "the builtin manifest is model-facing and ends the run through then" do
    catalog = Catalog.unconfigured()

    assert %{"request_access" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert Enum.map(manifest.views, &{&1.key, &1.source}) == [{"grant_scopes", "grant_scopes"}]
    assert manifest.chains == ["end"]
    assert manifest.then == ["end"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "request_access")

    input = %{
      @input
      | args: args([%{"kind" => "directory", "name" => "./secrets"}])
    }

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == RequestAccess.run(input)["emit"]
  end
end
