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

  defp priced_config do
    Omunculus.Fixtures.config("""
    [models.haiku]
    api = "openai-completions"
    url = "http://localhost:1/v1"
    timeout_ms = 1000
    model = "claude-haiku-5-5"
    price = { input = 1.0, output = 2.0, cache_write = 0.0, cache_read = 0.0 }

    [models.opus]
    api = "openai-completions"
    url = "http://localhost:1/v1"
    timeout_ms = 1000
    model = "claude-opus-5"
    price = { input = 10.0, output = 20.0, cache_write = 0.0, cache_read = 0.0 }

    [models.mystery]
    api = "openai-completions"
    url = "http://localhost:1/v1"
    timeout_ms = 1000
    model = "mystery-1"

    [agents.a]
    depth = 0
    model = "haiku"
    text = "a"

    [agents.b]
    depth = 1
    model = "mystery"
    text = "b"
    """)
  end

  test "each call is priced by the config model that made it, per agent and per work" do
    totals = Omunculus.Usage.sum([%{"usage" => @anthropic}])
    cheap = (12 * 1.0 + 300 * 2.0) / 1.0e6
    call = fn agent, work, reply -> %{agent: agent, work: work, reply: reply, totals: totals} end

    usage =
      Omunculus.Server.Contract.usage(
        [
          # The provider's id alone, as master recorded it.
          call.("a", "w2", %{"model" => "claude-haiku-5-5"}),
          # The config key beside the provider's id.
          call.("a", "w2", %{"model" => "claude-opus-5", "model_key" => "opus"}),
          call.("b", "w3", %{"model" => "mystery-1", "model_key" => "mystery"}),
          call.("a", "w1", %{}),
          call.("a", "", %{"model" => "claude-haiku-5-5", "model_key" => "haiku"})
        ],
        %{"w1" => nil, "w2" => "w1", "w3" => "w1"},
        priced_config()
      )

    [a, b] = usage.agents
    assert_in_delta a.usd, cheap * 13, 1.0e-12
    assert a.models == ["haiku", "opus"]
    assert b.usd == nil and b.unpriced == ["mystery"]
    assert usage.total.unpriced == ["mystery"]
    assert usage.total.replies == 5
    assert_in_delta usage.total.usd, a.usd, 1.0e-12

    by = Map.new(usage.works, &{&1.work, &1})
    assert Map.keys(by) |> Enum.sort() == ["", "w1", "w2", "w3"]
    assert [%{model: "haiku", provider: "claude-haiku-5-5"}, %{model: "opus"}] = by["w2"].calls
    assert_in_delta by["w2"].own.usd, cheap + cheap * 10, 1.0e-12
    assert by["w3"].own.usd == nil
    # The branch of w1 holds its own call and those of w2 and w3; "" holds no work's.
    assert by["w1"].branch.replies == 4 and by["w1"].own.replies == 1
    assert_in_delta by["w1"].branch.usd, by["w2"].own.usd + cheap, 1.0e-12
    assert by[""].branch.replies == 1
  end

  test "the cost view formats the server's dollars and names a model with no price" do
    script = """
    if (Usage.money(0.5) !== "US$ 0.50") throw Error(Usage.money(0.5));
    if (Usage.money(0.00123) !== "US$ 0.0012") throw Error(Usage.money(0.00123));
    if (Usage.money(12) !== "US$ 12.00") throw Error("whole");
    const data = {
      agents: [{agent: "seller", models: ["haiku"], usd: 0.0123}, {agent: "designer", models: ["mystery"], usd: null}],
      works: [{work: "w1", own: {usd: 0.0123}, branch: {usd: 0.0123}, calls: []}],
      total: {usd: 0.0123, unpriced: ["mystery"]}
    };
    const spend = Usage.spend(data);
    if (spend.agents.seller.usd !== 0.0123 || spend.agents.designer.usd !== null) throw Error(JSON.stringify(spend));
    if (spend.total.usd !== 0.0123 || spend.works.w1.branch.usd !== 0.0123) throw Error("total");
    const lines = Usage.unpriced(spend.total);
    if (lines.join() !== "no price set for mystery in the project config") throw Error(lines.join());
    if (Usage.unpriced({usd: 1, unpriced: []}).length !== 0) throw Error("all priced says nothing");
    const none = Usage.spend(null);
    if (none.total.usd !== 0 || none.total.unpriced.length !== 0) throw Error("before the server answers");
    """

    assert {"", 0} = GuiModules.run(["Usage"], script)
  end
end
