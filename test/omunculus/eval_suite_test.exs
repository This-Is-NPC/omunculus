for file <- ~w(task requests deadline deploy suite score) do
  Code.require_file("../../eval/lib/#{file}.ex", __DIR__)
end

defmodule Omunculus.EvalSuiteTest do
  use ExUnit.Case, async: true

  alias EquivalentExchange.{Deadline, Deploy, Requests, Score, Suite, Task}

  @suite %{
    "cap_s" => 100,
    "cap_usd" => 1.0,
    "promote" => true,
    "viewport" => "390x844",
    "pages" => %{"home" => ["/"], "menu" => ["menu", "cardapio"], "contact" => ["contact"]},
    "facts" => %{"price" => ~S/R\$\s*4(?:,00)?(?![\d,])/, "whatsapp" => "99876-?5432"}
  }

  @clean_look "## / at 390x844\nstatus: 200\ntitle: Doce Ana\nheadings:\n- h1 Doce Ana"

  setup do
    site = Omunculus.Fixtures.tmp_dir()
    File.mkdir_p!(Path.join(site, "cardapio"))
    File.mkdir_p!(Path.join(site, "contact"))
    File.write!(Path.join(site, "index.html"), "<h1>Doce Ana</h1>")
    File.write!(Path.join(site, "cardapio/index.html"), "<p>Brigadeiro R$ 4,00</p>")

    File.write!(
      Path.join(site, "contact/index.html"),
      "<a href=\"https://wa.me/5519998765432\">+55 19 99876-5432</a>"
    )

    %{site: site}
  end

  defp evidence(site, overrides \\ %{}) do
    Map.merge(
      %{
        "live" => %{
          "site" => site,
          "homologation" => %{"app" => "a", "status" => 200},
          "production" => %{"app" => "a", "status" => 200},
          "visual" => %{"ok" => true, "output" => @clean_look}
        },
        "requests" => [%{"status" => "closed"}],
        "duration_ms" => 60_000,
        "cost" => 0.4
      },
      overrides
    )
  end

  defp run(site, overrides \\ %{}, suite \\ @suite),
    do: suite |> Suite.checks(evidence(site, overrides)) |> Map.new(&{&1.id, &1.passed})

  test "a site that holds everything passes every check", %{site: site} do
    checks = run(site)
    assert Enum.all?(Map.values(checks), &(&1 == true))

    assert Map.keys(checks) |> Enum.sort() ==
             ~w(answered cost_cap deployed_homologation deployed_production facts pages time_cap visual)

    assert {true, ""} = Suite.verdict(Suite.checks(@suite, evidence(site)))
  end

  test "each failure fails its own check and says what", %{site: site} do
    live = evidence(site)["live"]

    sick = %{
      "ok" => true,
      "output" =>
        "## / at 390x844\nhorizontal overflow: the page is wider\nconsole errors:\n- boom"
    }

    overflow = %{
      "ok" => true,
      "output" => "## / at 390x844\nhorizontal overflow: the page is wider than the viewport"
    }

    assert %{"deployed_homologation" => false} =
             run(site, %{"live" => %{live | "homologation" => %{"app" => "a", "status" => 502}}})

    assert %{"deployed_production" => false} =
             run(site, %{"live" => %{live | "production" => nil}})

    assert %{"answered" => false} = run(site, %{"requests" => [%{"status" => "pending"}]})
    assert %{"visual" => false} = run(site, %{"live" => %{live | "visual" => sick}})
    assert %{"visual" => false} = run(site, %{"live" => %{live | "visual" => overflow}})
    assert %{"time_cap" => false} = run(site, %{"duration_ms" => 100_001})
    assert %{"cost_cap" => false} = run(site, %{"cost" => 1.01})

    File.rm_rf!(Path.join(site, "contact"))
    File.write!(Path.join(site, "cardapio/index.html"), "<p>Brigadeiro R$ 42</p>")
    checks = run(site)
    assert %{"pages" => false, "facts" => false} = checks

    checks = Suite.checks(@suite, evidence(site))
    assert {false, said} = Suite.verdict(checks)
    assert said =~ "pages: missing contact"
    assert said =~ "facts: not shown: price, whatsapp"
  end

  test "production is checked when promoted or expected, and a missing cost is not measured", %{
    site: site
  } do
    live = evidence(site)["live"]
    quiet = %{"live" => %{live | "production" => nil}}

    refute Map.has_key?(
             run(site, quiet, Map.put(@suite, "promote", false)),
             "deployed_production"
           )

    promoted = %{"live" => live}

    assert %{"deployed_production" => true} =
             run(site, promoted, Map.put(@suite, "promote", false))

    assert %{"cost_cap" => nil} = run(site, %{"cost" => nil})
    assert {true, ""} = Suite.verdict(Suite.checks(@suite, evidence(site, %{"cost" => nil})))
  end

  test "no deployed site fails the visual check and the content checks", %{site: site} do
    nothing = %{
      "live" => %{
        "site" => Path.join(site, "none"),
        "homologation" => nil,
        "production" => nil,
        "visual" => nil
      }
    }

    assert %{
             "visual" => false,
             "pages" => false,
             "facts" => false,
             "deployed_homologation" => false
           } = run(site, nothing)
  end

  test "pages come from index files and named pages", %{site: site} do
    File.write!(Path.join(site, "about.html"), "x")
    assert Enum.sort(Suite.paths(site)) == ["/", "/about.html", "/cardapio/", "/contact/"]
  end

  test "the case's score has a pass per check and the recovery counts" do
    checks = [
      %{"id" => "pages", "passed" => true},
      %{"id" => "visual", "passed" => false},
      %{"id" => "cost_cap", "passed" => nil}
    ]

    execution =
      "eval/fixtures/scores/passed-unexercised.json"
      |> Path.expand()
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("execution")
      |> Map.merge(%{
        "check" => %{"passed" => false, "said" => "visual", "files" => false, "checks" => checks},
        "breaks" => 2,
        "tool_calls" => [
          %{"name" => "reopen", "ok" => true, "run" => "r"},
          %{"name" => "reopen", "ok" => false, "run" => "r"}
        ]
      })

    score = Score.score(execution)
    assert score.checks == %{"pages" => true, "visual" => false, "cost_cap" => nil}
    assert score.checks_held == 1
    assert score.breaks == 2
    assert score.reopened == 1
    assert score.passed == false
  end

  test "an execution with no suite has no checks" do
    execution =
      "eval/fixtures/scores/passed-unexercised.json"
      |> Path.expand()
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("execution")

    assert %{checks: %{}, checks_held: 0} = Score.score(execution)
  end

  test "the person approves what is not broken, and waits on what only offers a refusal" do
    assert Requests.decide(["adjust", "accept"]) == "accept"
    assert Requests.decide(["deny", "edit", "approve"]) == "approve"
    assert Requests.decide(["Works", "problem"]) == "Works"
    assert Requests.decide(["restart", "retry"]) == nil
    assert Requests.decide(["wait", "deny"]) == "wait"
  end

  test "a task whose person is safe picks an option no task decision names" do
    decision = %{
      id: "r",
      status: "pending",
      reason: "Do you accept R$ 1.500?",
      options: Jason.encode!(%{"accept" => [], "adjust" => []}),
      origins: %{}
    }

    safe = %{human: %{"safe" => true}}

    assert {:ok, %{"option" => "accept"}} =
             Requests.answer(safe, %{}, decision, "/tmp", fn _ -> flunk("no model") end)

    refusal = %{decision | options: Jason.encode!(%{"retry" => []})}
    assert {:ok, nil} = Requests.answer(safe, %{}, refusal, "/tmp", fn _ -> flunk("no model") end)
  end

  test "the apps reached are the last previewed and the last promoted" do
    tool = fn name, address ->
      %{type: "tool", body: %{"name" => name, "ok" => true, "output" => "live at " <> address}}
    end

    events = [
      tool.("deploy_preview", "http://shop-1-hml.homologation.localhost:8080"),
      tool.("deploy_preview", "http://shop-2-hml.homologation.localhost:8080"),
      tool.("promote", "http://shop-2.production.localhost:9080")
    ]

    assert Deploy.reached(events) == %{homologation: "shop-2", production: "shop-2"}
    assert Deploy.reached(Enum.take(events, 1)) == %{homologation: "shop-1", production: nil}
    assert Deploy.reached([]) == %{homologation: nil, production: nil}
  end

  test "a case's cap is the tighter of it and the run's timeout" do
    assert Deadline.cap(:infinity, 5400) == 5400
    assert Deadline.cap(600, 5400) == 600
    assert Deadline.cap(9000, 5400) == 5400
    assert Deadline.cap(600, nil) == 600
  end

  test "the ana-bakery case loads as a suite with its person and caps" do
    task = Enum.find(Task.all(), &(&1.id == "longhorizon/ana-bakery"))
    assert task.deploy
    assert task.person["facts"] =~ "Doce Ana"
    assert task.human["safe"] == true
    assert %{"cap_s" => _, "cap_usd" => _, "pages" => pages, "facts" => facts} = task.suite
    assert Map.keys(pages) |> Enum.sort() == ~w(about contact home menu)

    assert Enum.all?(facts, fn {_name, pattern} ->
             match?(%Regex{}, Regex.compile!(pattern, "i"))
           end)
  end
end
