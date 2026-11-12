defmodule Omunculus.GuiUsageTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @anthropic %{
    "input_tokens" => 12,
    "cache_creation_input_tokens" => 5000,
    "cache_read_input_tokens" => 20_000,
    "output_tokens" => 300
  }
  @openai %{
    "prompt_tokens" => 100,
    "prompt_tokens_details" => %{"cached_tokens" => 40},
    "completion_tokens" => 7,
    "cost" => 0.5
  }

  test "the server sums the provider fixtures as the client contract says" do
    assert %{input: 25_012, cached: 20_000, output: 300} =
             Omunculus.Usage.sum([%{"usage" => @anthropic}])

    assert %{input: 100, cached: 40, output: 7, cost: 0.5} =
             Omunculus.Usage.sum([%{"usage" => @openai}])
  end

  test "the server splits the input into fresh, written and cached tokens" do
    assert %{input: 25_012, fresh: 12, cache_write: 5000, cached: 20_000} =
             Omunculus.Usage.sum([%{"usage" => @anthropic}])

    assert %{input: 100, fresh: 60, cache_write: 0, cached: 40} =
             Omunculus.Usage.sum([%{"usage" => @openai}])
  end

  test "the cost is each kind of token at its price per million" do
    price = %{input: 0.10, output: 0.50, cache_write: 0.125, cache_read: 0.01}
    totals = Omunculus.Usage.sum([%{"usage" => @anthropic}])
    # 12 * 0.10 + 300 * 0.50 + 5000 * 0.125 + 20000 * 0.01, per million.
    assert_in_delta Omunculus.Usage.spend(totals, price), 976.2 / 1.0e6, 1.0e-12
  end

  test "an agent's dollars are its model's price, and a model with none is named" do
    totals = Omunculus.Usage.sum([%{"usage" => @anthropic}])
    price = %{input: 1.0, output: 2.0, cache_write: 0.0, cache_read: 0.0}

    usage =
      Omunculus.Server.Contract.usage(
        [{"a", totals}, {"b", totals}],
        %{"a" => "haiku", "b" => "mystery"},
        %{"haiku" => price, "mystery" => nil}
      )

    [a, b] = usage.agents
    assert_in_delta a.usd, (12 * 1.0 + 300 * 2.0) / 1.0e6, 1.0e-12
    assert b.usd == nil
    assert_in_delta usage.total.usd, a.usd, 1.0e-12
    assert usage.total.unpriced == ["mystery"]
    assert usage.total.replies == 2
  end

  test "Usage.add matches Usage.sum on the same fixtures" do
    script = """
    const anthropic = #{Jason.encode!(@anthropic)};
    const openai = #{Jason.encode!(@openai)};
    const one = usage => Usage.add(Usage.tally(), usage);
    const a = one(anthropic);
    if (a.input !== 25012 || a.cached !== 20000 || a.output !== 300 || a.calls !== 1 || a.priced !== 0) throw Error(JSON.stringify(a));
    const o = one(openai);
    if (o.input !== 100 || o.cached !== 40 || o.output !== 7 || o.cost !== 0.5 || o.priced !== 1) throw Error(JSON.stringify(o));
    const all = Usage.add(Usage.add(Usage.tally(), anthropic), openai);
    if (all.input !== 25112 || all.cached !== 20040 || all.output !== 307 || all.calls !== 2) throw Error(JSON.stringify(all));
    if (Usage.add(Usage.tally(), undefined).calls !== 1) throw Error("missing usage");
    """

    assert {"", 0} = GuiModules.run(["Usage"], script)
  end

  test "the cost view formats the server's dollars and names a model with no price" do
    script = """
    if (Usage.money(0.5) !== "US$ 0.50") throw Error(Usage.money(0.5));
    if (Usage.money(0.00123) !== "US$ 0.0012") throw Error(Usage.money(0.00123));
    if (Usage.money(12) !== "US$ 12.00") throw Error("whole");
    const data = {
      agents: [{agent: "seller", model: "haiku", usd: 0.0123}, {agent: "designer", model: "mystery", usd: null}],
      total: {usd: 0.0123, unpriced: ["mystery"]}
    };
    const spend = Usage.spend(data);
    if (spend.agents.seller.usd !== 0.0123 || spend.agents.designer.usd !== null) throw Error(JSON.stringify(spend));
    if (spend.total.usd !== 0.0123) throw Error("total");
    const lines = Usage.unpriced(spend.total);
    if (lines.join() !== "no price set for mystery in the project config") throw Error(lines.join());
    if (Usage.unpriced({usd: 1, unpriced: []}).length !== 0) throw Error("all priced says nothing");
    const none = Usage.spend(null);
    if (none.total.usd !== 0 || none.total.unpriced.length !== 0) throw Error("before the server answers");
    """

    assert {"", 0} = GuiModules.run(["Usage"], script)
  end
end
