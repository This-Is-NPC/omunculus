defmodule Omunculus.Tools.DelegateTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Delegate

  @input %{
    name: "delegate",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "emits delegate with the given title and body" do
    input = %{@input | args: %{"title" => "review the design", "body" => "please take a look"}}

    assert Delegate.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "delegate",
                 "body" => %{"title" => "review the design", "body" => "please take a look"}
               }
             ]
           }
  end

  test "does not forward stage or agent from args" do
    input = %{
      @input
      | args: %{
          "title" => "review the design",
          "body" => "please take a look",
          "stage" => "review",
          "agent" => "worker"
        }
    }

    assert Delegate.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "delegate",
                 "body" => %{"title" => "review the design", "body" => "please take a look"}
               }
             ]
           }
  end

  test "emits an explicit workspace" do
    input = %{
      @input
      | args: %{
          "title" => "review the design",
          "body" => "please take a look",
          "workspace" => "app"
        }
    }

    assert Delegate.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "delegate",
                 "body" => %{
                   "title" => "review the design",
                   "body" => "please take a look",
                   "workspace" => "app"
                 }
               }
             ]
           }
  end

  test "refuses without a title" do
    assert Delegate.run(%{@input | args: %{"body" => "please take a look"}}) == %{
             "ok" => false,
             "output" => "title required",
             "emit" => []
           }
  end

  test "refuses without a body" do
    assert Delegate.run(%{@input | args: %{"title" => "review the design"}}) == %{
             "ok" => false,
             "output" => "body required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers delegate with triggers == [\"model\"]" do
    catalog = Catalog.unconfigured()

    assert %{"delegate" => manifest} = catalog
    assert manifest.triggers == ["model"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "delegate")
    input = %{@input | args: %{"title" => "review the design", "body" => "please take a look"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Delegate.run(input)["emit"]
  end
end
