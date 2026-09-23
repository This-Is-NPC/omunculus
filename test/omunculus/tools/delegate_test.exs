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

  test "emits delegate with the given title and goal" do
    input = %{@input | args: %{"title" => "review the design", "goal" => "please take a look"}}

    assert Delegate.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "delegate",
                 "body" => %{"title" => "review the design", "goal" => "please take a look"}
               }
             ]
           }
  end

  test "forwards an agent but not a stage" do
    input = %{
      @input
      | args: %{
          "title" => "review the design",
          "goal" => "please take a look",
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
                 "body" => %{
                   "title" => "review the design",
                   "goal" => "please take a look",
                   "agent" => "worker"
                 }
               }
             ]
           }
  end

  test "emits an explicit workspace" do
    input = %{
      @input
      | args: %{
          "title" => "review the design",
          "goal" => "please take a look",
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
                   "goal" => "please take a look",
                   "workspace" => "app"
                 }
               }
             ]
           }
  end

  test "refuses without a title" do
    assert Delegate.run(%{@input | args: %{"goal" => "please take a look"}}) == %{
             "ok" => false,
             "output" => "title required",
             "emit" => []
           }
  end

  test "refuses without a goal" do
    assert Delegate.run(%{@input | args: %{"title" => "review the design"}}) == %{
             "ok" => false,
             "output" => "goal required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers delegate as a chain step only" do
    catalog = Catalog.unconfigured()

    assert %{"delegate" => manifest} = catalog
    assert manifest.triggers == ["chain"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "delegate")
    input = %{@input | args: %{"title" => "review the design", "goal" => "please take a look"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Delegate.run(input)["emit"]
  end
end
