defmodule Omunculus.SalesDeskProposalTest do
  use ExUnit.Case, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Tool.Catalog

  @tools Path.expand("packs/sales-desk/tools")
  @pages ~w(Home Menu About Contact)

  setup do
    %{root: Fixtures.tmp_dir()}
  end

  # Runs a tool of the pack the way the harness does: the call as JSON on stdin.
  defp call(name, args, view, root) do
    input = Path.join(root, "#{name}.json")

    File.write!(
      input,
      Jason.encode!(%{
        name: name,
        args: args,
        view: Map.put_new(view, "work", %{"id" => "w1", "stage" => "propose"}),
        roots: [root]
      })
    )

    {output, 0} =
      System.cmd("sh", ["-c", ~s(exec "$0" < "$1"), Path.join([@tools, name, "run"]), input])

    Jason.decode!(output)
  end

  defp bodies(%{"emit" => emit}), do: Map.new(emit, &{&1["body"]["name"], &1["body"]})

  defp data(out), do: out |> bodies() |> get_in(["proposal-w1", "content"]) |> Jason.decode!()

  # What the harness gives the next call: the versions the emits made, written by `tool`.
  defp view_after(out, prior \\ %{}, tool \\ "proposal") do
    old = prior["artifacts"] || []

    new =
      Enum.reduce(bodies(out), old, fn {name, body}, acc ->
        number = Enum.count(acc, &(&1["name"] == name)) + 1
        version = %{"name" => name, "version" => number, "tool" => tool, "kind" => body["kind"]}

        version =
          if body["media_type"] == "application/json",
            do: Map.put(version, "data", Jason.decode!(body["content"])),
            else: version

        acc ++ [version]
      end)

    %{"artifacts" => new, "work" => %{"id" => "w1", "stage" => "propose"}}
  end

  defp forged(name, number, data, tool \\ "put_artifact") do
    %{"artifacts" => [%{"name" => name, "version" => number, "tool" => tool, "data" => data}]}
  end

  defp write(fields, view, root, args \\ %{}),
    do: call("proposal", Map.merge(%{"fields" => fields}, args), view, root)

  test "the pack's tools are valid manifests reading the proposals' artifacts" do
    catalog = Catalog.discover(%{paths: [@tools], inline: %{}, skills: []})

    for name <- ~w(proposal render_proposal next_stage) do
      assert %{^name => manifest} = catalog

      assert [%{include: ["data"], prefix: "proposal-"}] =
               Enum.filter(manifest.views, &(&1.source == "artifacts"))
    end
  end

  describe "proposal" do
    test "prices from the desk's table and renders the client's document", %{root: root} do
      # The workspace's own template is never read: the pack's is.
      File.mkdir_p!(Path.join(root, "templates"))
      File.write!(Path.join([root, "templates", "proposal.md"]), "forged")

      fields = %{
        "client" => "Ana",
        "business" => "Doce Ana",
        "scope" => %{"pages" => @pages ++ ["Blog", "Shop"], "features" => ["WhatsApp button"]},
        "pending" => ["logo", "photos\nof the shop"]
      }

      out = write(fields, %{}, root)

      assert %{"ok" => true, "output" => "proposal saved: status draft, total R$ 2,100;" <> _} =
               out

      assert %{"emit" => [%{"type" => "artifact"}, %{"type" => "artifact"}]} = out

      assert %{"status" => "draft", "work" => "w1", "price" => price} = data(out)
      assert price["total"] == 2100
      assert Enum.map(price["lines"], & &1["amount"]) == [1500, 600]

      assert %{"kind" => "proposal", "media_type" => "application/json", "base" => 0} =
               bodies(out)["proposal-w1"]

      assert %{"kind" => "document", "media_type" => "text/markdown", "content" => document} =
               bodies(out)["proposal-w1.md"]

      assert document =~ "# Proposal: Ana (Doce Ana)"
      assert document =~ "### Pages\n- Home\n- Menu\n- About\n- Contact\n- Blog\n- Shop"
      assert document =~ "- Extra pages: 2 x R$ 300: R$ 600"
      assert document =~ "Total: R$ 2,100"
      assert document =~ "## Pending\n- logo\n- photos\n  of the shop"
      refute document =~ "forged"
      refute document =~ "{{"
      refute document =~ "<!--"
    end

    test "a later version keeps the data and the discount, and builds on what it read", %{
      root: root
    } do
      first = write(%{"scope" => %{"pages" => @pages}}, %{}, root)
      assert data(first)["price"]["total"] == 1500

      second = write(%{"status" => "sent"}, view_after(first), root, %{"discount" => 10})
      assert %{"status" => "sent", "scope" => %{"pages" => @pages}} = data(second)
      assert data(second)["price"]["total"] == 1350
      assert %{"base" => 1} = bodies(second)["proposal-w1"]
      assert bodies(second)["proposal-w1.md"]["content"] =~ "- Discount 10%: -R$ 150"

      third = write(%{"status" => "accepted"}, view_after(second, view_after(first)), root)
      assert data(third)["price"]["total"] == 1350
      assert %{"base" => 2} = bodies(third)["proposal-w1"]
    end

    test "a discount given before the pages is kept for when they come", %{root: root} do
      first = write(%{"client" => "Ana"}, %{}, root, %{"discount" => 5})
      refute Map.has_key?(data(first), "price")
      assert data(first)["discount"] == 5

      second = write(%{"scope" => %{"pages" => @pages}}, view_after(first), root)
      assert data(second)["price"]["total"] == 1425
    end

    test "refuses malformed input with a message, never a crash", %{root: root} do
      refuse = fn fields, args -> write(fields, %{}, root, args) end

      assert %{"ok" => false, "output" => "the desk gives up to 10% off" <> _} =
               refuse.(%{}, %{"discount" => 11})

      for bad <- [true, "10", nil, -1, [1]] do
        assert %{"ok" => false, "output" => "discount is a percentage" <> _} =
                 refuse.(%{}, %{"discount" => bad})
      end

      assert %{"ok" => false, "output" => "the desk works out price" <> _} =
               refuse.(%{"price" => %{"total" => 1}}, %{})

      assert %{"output" => "the desk works out discount" <> _} = refuse.(%{"discount" => 1}, %{})

      for status <- ["lost", nil, 3] do
        assert %{
                 "ok" => false,
                 "output" => "status is one of: draft, sent, accepted, refused, approved"
               } =
                 refuse.(%{"status" => status}, %{})
      end

      assert %{"output" => "scope must be an object"} = refuse.(%{"scope" => "x"}, %{})

      assert %{"output" => "scope.pages must be a list of text"} =
               refuse.(%{"scope" => %{"pages" => "Home"}}, %{})

      assert %{"output" => "scope.pages must be a list of text"} =
               refuse.(%{"scope" => %{"pages" => [%{"a" => 1}]}}, %{})

      assert %{"output" => "pending must be a list of text"} = refuse.(%{"pending" => [1]}, %{})
      assert %{"output" => "client must be text"} = refuse.(%{"client" => %{}}, %{})

      assert %{"output" => "colour is not a field of the proposal"} =
               refuse.(%{"colour" => "red"}, %{})

      assert %{"output" => "design.state is one of: approved, waived"} =
               refuse.(%{"design" => %{"state" => "not approved yet"}}, %{})

      assert %{"output" => "fields must be an object"} = call("proposal", %{}, %{}, root)

      assert %{"output" => "fields must be an object"} =
               call("proposal", %{"fields" => []}, %{}, root)
    end

    test "only versions the proposal tool wrote count, and one work's never stand in for another's",
         %{root: root} do
      # Another tool's version under the name is no proposal: the tool starts afresh, on its number.
      out =
        write(
          %{"client" => "Bia"},
          forged("proposal-w1", 3, %{"business" => "Fake", "work" => "w1"}),
          root
        )

      refute Map.has_key?(data(out), "business")
      assert %{"base" => 3} = bodies(out)["proposal-w1"]

      # Another work's proposal leaves this work's free.
      other = forged("proposal-w0", 1, %{"business" => "Doce Ana", "work" => "w0"}, "proposal")
      out = write(%{"client" => "Bia"}, other, root)
      refute Map.has_key?(data(out), "business")
      assert %{"base" => 0} = bodies(out)["proposal-w1"]

      # A version whose JSON is not an object is refused with what to do.
      broken = forged("proposal-w1", 1, [1, 2], "proposal")

      assert %{"ok" => false, "output" => "version 1 of proposal-w1 is not a JSON object" <> _} =
               write(%{}, broken, root)

      assert %{"ok" => false} = call("render_proposal", %{}, broken, root)
    end
  end

  describe "render_proposal" do
    test "renders the latest data again, as the next version of the document", %{root: root} do
      first = write(%{"client" => "Ana", "scope" => %{"pages" => @pages}}, %{}, root)
      out = call("render_proposal", %{}, view_after(first), root)
      assert %{"ok" => true, "emit" => [%{"body" => body}]} = out
      assert %{"name" => "proposal-w1.md", "kind" => "document", "base" => 1} = body
      assert body["content"] =~ "Total: R$ 1,500"
    end

    test "refuses a request with no proposal", %{root: root} do
      assert %{"ok" => false, "output" => "there is no proposal" <> _} =
               call("render_proposal", %{}, %{"artifacts" => []}, root)
    end
  end

  describe "wait_client" do
    test "the manifest loads and ends the run" do
      catalog = Catalog.discover(%{paths: [@tools], inline: %{}, skills: []})
      assert %{"wait_client" => %{then: ["end"]}} = catalog
    end

    defp wait(stage, children, root) do
      view = %{"work" => %{"id" => "w1", "stage" => stage}, "children" => children}
      call("wait_client", %{"report" => "The client will decide later."}, view, root)
    end

    defp sale(state, waiting \\ nil),
      do: %{"workflow" => "sale", "assignee" => "seller", "state" => state, "waiting" => waiting}

    test "at sale it is refused until the seller's work broke, guiding the manager", %{root: root} do
      for child <- [
            sale("open"),
            sale("waiting", "child"),
            sale("waiting", "request"),
            sale("done")
          ] do
        assert %{
                 "ok" => false,
                 "output" =>
                   "wait refused at stage sale: the seller's sale work is not broken" <> _
               } =
                 wait("sale", [child], root)
      end

      assert %{
               "ok" => true,
               "emit" => [
                 %{"type" => "wait", "body" => %{"body" => "The client will decide later."}}
               ]
             } =
               wait("sale", [sale("waiting")], root)
    end

    test "other stages wait freely", %{root: root} do
      assert %{"ok" => true, "emit" => [%{"type" => "wait"}]} = wait("design", [], root)
    end
  end

  describe "start_sale" do
    test "hands the seller the request's goal and moves to stage sale", %{root: root} do
      view = %{
        "work" => %{
          "id" => "w1",
          "stage" => "start",
          "title" => "Padaria Sol",
          "goal" => "Quero um site."
        }
      }

      assert %{
               "ok" => true,
               "chain" => [
                 %{"name" => "continue", "args" => %{}},
                 %{
                   "name" => "delegate",
                   "args" => %{
                     "title" => "Padaria Sol: sale",
                     "goal" => "Quero um site.",
                     "workflow" => "sale"
                   }
                 }
               ]
             } = call("start_sale", %{}, view, root)
    end

    test "is refused after stage start", %{root: root} do
      view = %{"work" => %{"id" => "w1", "stage" => "sale", "goal" => "x"}}

      assert %{"ok" => false, "output" => "start_sale starts the sale at stage start" <> _} =
               call("start_sale", %{}, view, root)
    end
  end

  describe "next_stage" do
    defp stage(stage, view, root) do
      view = Map.put(view, "work", %{"id" => "w1", "stage" => stage})
      call("next_stage", %{"report" => "done"}, view, root)
    end

    test "propose holds once the price is worked out and the client accepted", %{root: root} do
      draft = write(%{"scope" => %{"pages" => @pages}}, %{}, root)

      assert %{
               "ok" => false,
               "output" => "stage propose does not hold yet: give the client the price" <> _
             } =
               stage("propose", view_after(draft), root)

      accepted = write(%{"status" => "accepted"}, view_after(draft), root)

      assert %{"ok" => true, "chain" => [%{"name" => "comment"}, %{"name" => "continue"}]} =
               stage("propose", view_after(accepted, view_after(draft)), root)
    end

    test "a proposal another tool wrote passes no gate", %{root: root} do
      whole = %{"status" => "accepted", "price" => %{"total" => 1}, "work" => "w1"}

      assert %{
               "ok" => false,
               "output" => "stage propose does not hold yet: write the proposal" <> _
             } =
               stage("propose", forged("proposal-w1", 1, whole), root)

      assert %{"ok" => true} = stage("propose", forged("proposal-w1", 1, whole, "proposal"), root)
    end

    test "qualify names what is missing, and wants a proposal first", %{root: root} do
      assert %{
               "ok" => false,
               "output" => "stage qualify does not hold yet: write the proposal" <> _
             } =
               stage("qualify", %{"artifacts" => []}, root)

      thin = write(%{"business" => "Doce Ana"}, %{}, root)
      assert %{"ok" => false, "output" => output} = stage("qualify", view_after(thin), root)
      assert output =~ "city, audience, decider"
      assert output =~ "scope.pages"

      whole = %{
        "business" => "Doce Ana",
        "city" => "Campinas",
        "audience" => "neighbours",
        "decider" => "Ana",
        "budget_timing" => "pending: no deadline",
        "problem" => "no site",
        "content" => %{"texts" => "yes", "products" => "yes", "contacts" => "pending: logo"},
        "scope" => %{"pages" => @pages}
      }

      assert %{"ok" => true} = stage("qualify", view_after(write(whole, %{}, root)), root)
    end

    test "design wants the state exactly, and the client's own answer to waive", %{root: root} do
      base = write(%{"client" => "Ana"}, %{}, root)
      assert %{"ok" => false} = stage("design", view_after(base), root)

      # No substring of a sentence passes.
      for state <- ["not approved yet", "approved, maybe", "Approved", ""] do
        assert %{"ok" => false} =
                 stage(
                   "design",
                   forged("proposal-w1", 1, %{"design" => %{"state" => state}}, "proposal"),
                   root
                 )
      end

      approved = write(%{"design" => %{"state" => "approved"}}, %{}, root)

      assert %{"ok" => false, "output" => "stage design" <> _} =
               stage("design", view_after(approved), root)

      address = write(%{"design" => %{"state" => "approved", "address" => "http://x"}}, %{}, root)
      assert %{"ok" => true} = stage("design", view_after(address), root)

      # Only the client waives the preview: their answer comes with it.
      assert %{"ok" => false, "output" => "only the client waives the preview" <> _} =
               write(%{"design" => %{"state" => "waived"}}, %{}, root)

      waived =
        write(%{"design" => %{"state" => "waived", "client_answer" => "no preview"}}, %{}, root)

      assert %{"ok" => true} = stage("design", view_after(waived), root)
    end

    test "estimate wants the project manager's answer", %{root: root} do
      base = write(%{"client" => "Ana"}, %{}, root)

      assert %{"ok" => false, "output" => "stage estimate" <> _} =
               stage("estimate", view_after(base), root)

      assessed = write(%{"assessment" => %{"answer" => "yes"}}, %{}, root)
      assert %{"ok" => true} = stage("estimate", view_after(assessed), root)
    end

    test "the seller, a child of the manager's work, writes the engagement's proposal", %{
      root: root
    } do
      seller = %{"id" => "w2", "parent_id" => "w1", "stage" => "estimate"}
      out = write(%{"assessment" => %{"answer" => "yes"}}, %{"work" => seller}, root)
      assert %{"proposal-w1" => _, "proposal-w1.md" => _} = bodies(out)

      view = Map.put(view_after(out), "work", seller)
      assert %{"ok" => true} = call("next_stage", %{"report" => "done"}, view, root)
    end

    test "signoff wants the owner's approval and the approved status", %{root: root} do
      approved = write(%{"status" => "approved"}, %{}, root)
      cause = %{"type" => "reply", "body" => ~s({"option":"approve"})}

      assert %{"ok" => false, "output" => "stage signoff" <> _} =
               stage("signoff", view_after(approved), root)

      assert %{"ok" => true} =
               stage("signoff", Map.put(view_after(approved), "cause", cause), root)

      accepted = write(%{"status" => "accepted"}, %{}, root)

      assert %{"ok" => false, "output" => "stage signoff does not hold yet: set the status" <> _} =
               stage("signoff", Map.put(view_after(accepted), "cause", cause), root)
    end

    test "the manager's stages read the works below and the delivery", %{root: root} do
      approved = write(%{"status" => "approved"}, %{}, root)
      done = fn assignee, goal -> %{"assignee" => assignee, "state" => "done", "goal" => goal} end

      with_children = fn view, children -> Map.put(view, "children", children) end

      assert %{"ok" => false, "output" => "stage sale" <> _} =
               stage("sale", view_after(approved), root)

      assert %{"ok" => true} =
               stage(
                 "sale",
                 with_children.(view_after(approved), [done.("seller", "sale")]),
                 root
               )

      refused = write(%{"status" => "refused"}, %{}, root)

      assert %{"ok" => false, "output" => "stage sale does not hold yet: the client refused" <> _} =
               stage("sale", with_children.(view_after(refused), [done.("seller", "sale")]), root)

      assessment = done.("administrator", "Assessment only, build nothing: pages")
      build = done.("administrator", "Build the site")

      accepted =
        write(%{"delivery" => %{"address" => "http://h", "accepted" => "accepted"}}, %{}, root)

      unaccepted = write(%{"client" => "Ana"}, %{}, root)

      assert %{"ok" => false, "output" => "stage build does not hold yet: hand the dev team" <> _} =
               stage("build", with_children.(view_after(accepted), [assessment]), root)

      assert %{"ok" => false, "output" => "stage build does not hold yet: the client must" <> _} =
               stage("build", with_children.(view_after(unaccepted), [build]), root)

      assert %{"ok" => true} =
               stage("build", with_children.(view_after(accepted), [assessment, build]), root)

      assert %{"ok" => false, "output" => "stage handover" <> _} =
               stage("handover", view_after(accepted), root)

      live = write(%{"delivery" => %{"production" => "http://p"}}, %{}, root)
      assert %{"ok" => true} = stage("handover", view_after(live), root)
    end

    test "malformed data refuses instead of crashing", %{root: root} do
      scope = forged("proposal-w1", 1, %{"scope" => "Home"}, "proposal")
      assert %{"ok" => false, "output" => output} = stage("qualify", scope, root)
      assert output =~ "stage qualify does not hold yet"
      assert %{"ok" => false} = stage("qualify", forged("proposal-w1", 1, [], "proposal"), root)

      assert %{"ok" => false, "output" => "report required"} =
               call("next_stage", %{"report" => nil}, %{}, root)
    end
  end
end
