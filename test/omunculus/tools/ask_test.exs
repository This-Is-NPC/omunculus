defmodule Omunculus.Tools.AskTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Ask

  test "asks for a decision whose options call nothing, to the person when it says so" do
    assert %{"ok" => true, "emit" => [%{"type" => "request", "body" => body}]} =
             Ask.run(%{
               args: %{
                 "question" => "Discount of 15%?",
                 "options" => ["approve", "deny"],
                 "to" => "person"
               }
             })

    assert body == %{
             "reason" => "Discount of 15%?",
             "options" => %{"approve" => [], "deny" => []},
             "to" => "person"
           }
  end

  test "asks a free-text question without inventing decision options" do
    for extra <- [%{}, %{"options" => []}] do
      assert %{"ok" => true, "emit" => [%{"type" => "request", "body" => body}]} =
               Ask.run(%{args: Map.merge(%{"question" => "Which logo?"}, extra)})

      assert body == %{"reason" => "Which logo?", "options" => %{}}
    end
  end

  test "refuses fewer than two different answers, an answer that is not a short name, or no question" do
    for args <- [
          %{"question" => "q", "options" => ["only"]},
          %{"question" => "q", "options" => ["same", "same"]},
          %{"question" => "q", "options" => ["a", ""]},
          %{"question" => "q", "options" => ["approve: start the build", "deny"]},
          %{"question" => "q", "options" => ["Approve", "deny"]},
          %{"options" => ["a", "b"]}
        ] do
      assert %{"ok" => false} = Ask.run(%{args: args}), inspect(args)
    end
  end

  test "the builtin catalog discovers ask for models, ending the run" do
    assert %{"ask" => %{triggers: ["model"], then: ["end"]}} = Catalog.unconfigured()
  end
end
