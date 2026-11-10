defmodule Omunculus.SalesDeskProposalTest do
  use ExUnit.Case, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Tool.Catalog

  @tools Path.expand("packs/sales-desk/tools")
  @template Path.expand("packs/sales-desk/workspace/templates/proposal.md")

  setup do
    root = Fixtures.tmp_dir()
    File.mkdir_p!(Path.join(root, "templates"))
    File.cp!(@template, Path.join([root, "templates", "proposal.md"]))
    %{root: root}
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

  defp data(out), do: out |> bodies() |> get_in(["proposal", "content"]) |> Jason.decode!()

  # What the harness gives the next call: the artifacts the emits made.
  defp view_after(out, work \\ "w1") do
    versions =
      for {_name, body} <- bodies(out), body["name"] == "proposal" do
        %{"name" => "proposal", "version" => 1, "data" => Jason.decode!(body["content"])}
      end

    %{"artifacts" => versions, "work" => %{"id" => work, "stage" => "propose"}}
  end

  @pages ~w(Home Menu About Contact)

  test "the pack's tools are valid manifests with the artifacts view" do
    catalog = Catalog.discover(%{paths: [@tools], inline: %{}, skills: []})

    for name <- ~w(proposal render_proposal next_stage) do
      assert %{^name => manifest} = catalog

      assert [%{source: "artifacts", include: ["data"]}] =
               Enum.filter(manifest.views, &(&1.source == "artifacts"))
    end
  end

  describe "proposal" do
    test "prices from the desk's table and renders the client's document", %{root: root} do
      out =
        call(
          "proposal",
          %{
            "fields" => %{
              "client" => "Ana",
              "business" => "Doce Ana",
              "scope" => %{
                "pages" => @pages ++ ["Blog", "Shop"],
                "features" => ["WhatsApp button"]
              },
              "pending" => ["logo"]
            }
          },
          %{},
          root
        )

      assert %{"ok" => true, "output" => "proposal saved: status draft, total R$ 2,100"} = out
      assert %{"emit" => [%{"type" => "artifact"}, %{"type" => "artifact"}]} = out

      assert %{"status" => "draft", "work" => "w1", "price" => price} = data(out)
      assert price["total"] == 2100
      assert Enum.map(price["lines"], & &1["amount"]) == [1500, 600]

      assert %{"kind" => "proposal", "media_type" => "application/json"} =
               bodies(out)["proposal"]

      assert %{"kind" => "document", "media_type" => "text/markdown", "content" => document} =
               bodies(out)["proposal.md"]

      assert document =~ "# Proposal: Ana (Doce Ana)"
      assert document =~ "Status: draft"
      assert document =~ "### Pages\n- Home\n- Menu\n- About\n- Contact\n- Blog\n- Shop"
      assert document =~ "- Extra pages: 2 x R$ 300: R$ 600"
      assert document =~ "Total: R$ 2,100"
      assert document =~ "## Pending\n- logo"
      refute document =~ "{{"
      refute document =~ "<!--"
    end

    test "a later version keeps the earlier data, and the discount the desk may give", %{
      root: root
    } do
      first = call("proposal", %{"fields" => %{"scope" => %{"pages" => @pages}}}, %{}, root)
      assert data(first)["price"]["total"] == 1500

      second =
        call(
          "proposal",
          %{"fields" => %{"status" => "sent"}, "discount" => 10},
          view_after(first),
          root
        )

      assert %{"status" => "sent", "scope" => %{"pages" => @pages}} = data(second)
      assert %{"total" => 1350, "discount" => 10} = data(second)["price"]
      assert bodies(second)["proposal.md"]["content"] =~ "- Discount 10%: -R$ 150"

      # The discount stays for the next version.
      third = call("proposal", %{"fields" => %{"status" => "accepted"}}, view_after(second), root)
      assert data(third)["price"]["total"] == 1350
    end

    test "refuses what the desk does not decide", %{root: root} do
      refuse = &call("proposal", &1, &2, root)

      assert %{"ok" => false, "output" => "the desk gives up to 10% off" <> _} =
               refuse.(%{"fields" => %{}, "discount" => 11}, %{})

      assert %{"ok" => false, "output" => "the desk works out price: " <> _} =
               refuse.(%{"fields" => %{"price" => %{"total" => 1}}}, %{})

      assert %{
               "ok" => false,
               "output" => "status is one of: draft, sent, accepted, refused, approved"
             } =
               refuse.(%{"fields" => %{"status" => "lost"}}, %{})

      assert %{"ok" => false, "output" => "fields must be an object"} = refuse.(%{}, %{})
    end

    test "another request's proposal is not built upon", %{root: root} do
      first = call("proposal", %{"fields" => %{"business" => "Doce Ana"}}, %{}, root)
      other = call("proposal", %{"fields" => %{"client" => "Bia"}}, view_after(first, "w2"), root)
      assert %{"client" => "Bia", "work" => "w2"} = data(other)
      refute Map.has_key?(data(other), "business")
    end
  end

  describe "render_proposal" do
    test "renders the latest data again, as the next version of the document", %{root: root} do
      first =
        call(
          "proposal",
          %{"fields" => %{"client" => "Ana", "scope" => %{"pages" => @pages}}},
          %{},
          root
        )

      File.write!(
        Path.join([root, "templates", "proposal.md"]),
        "Hello {{client}}, {{price.total}}\n"
      )

      assert %{"ok" => true, "emit" => [%{"body" => body}]} =
               call("render_proposal", %{}, view_after(first), root)

      assert %{
               "name" => "proposal.md",
               "kind" => "document",
               "content" => "Hello Ana, R$ 1,500\n"
             } = body
    end

    test "refuses a request with no proposal", %{root: root} do
      assert %{"ok" => false, "output" => "there is no proposal" <> _} =
               call("render_proposal", %{}, %{"artifacts" => []}, root)
    end
  end

  describe "next_stage" do
    defp stage(stage, view, root) do
      view = Map.put(view, "work", %{"id" => "w1", "stage" => stage})
      call("next_stage", %{"report" => "done"}, view, root)
    end

    test "propose holds once the price is worked out and the client accepted", %{root: root} do
      draft = call("proposal", %{"fields" => %{"scope" => %{"pages" => @pages}}}, %{}, root)

      assert %{
               "ok" => false,
               "output" => "stage propose does not hold yet: give the client the price" <> _
             } =
               stage("propose", view_after(draft), root)

      accepted =
        call("proposal", %{"fields" => %{"status" => "accepted"}}, view_after(draft), root)

      assert %{"ok" => true, "chain" => [%{"name" => "comment"}, %{"name" => "continue"}]} =
               stage("propose", view_after(accepted), root)
    end

    test "qualify names what is missing, and wants a proposal first", %{root: root} do
      assert %{
               "ok" => false,
               "output" => "stage qualify does not hold yet: write the proposal" <> _
             } =
               stage("qualify", %{"artifacts" => []}, root)

      thin = call("proposal", %{"fields" => %{"business" => "Doce Ana"}}, %{}, root)
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

      full = call("proposal", %{"fields" => whole}, %{}, root)
      assert %{"ok" => true} = stage("qualify", view_after(full), root)
    end

    test "design and assess read their own parts", %{root: root} do
      base = call("proposal", %{"fields" => %{"design" => %{"preview" => "pending"}}}, %{}, root)
      assert %{"ok" => false} = stage("design", view_after(base), root)

      approved =
        call(
          "proposal",
          %{"fields" => %{"design" => %{"preview" => "https://x approved"}}},
          view_after(base),
          root
        )

      assert %{"ok" => true} = stage("design", view_after(approved), root)

      assert %{"ok" => false, "output" => "stage assess" <> _} =
               stage("assess", view_after(approved), root)

      assessed =
        call(
          "proposal",
          %{"fields" => %{"assessment" => %{"work" => "w2", "answer" => "yes"}}},
          view_after(approved),
          root
        )

      assert %{"ok" => true} = stage("assess", view_after(assessed), root)
    end
  end
end
