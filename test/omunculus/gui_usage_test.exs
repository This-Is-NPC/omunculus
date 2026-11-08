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
end
