Code.require_file("../../eval/lib/usage.ex", __DIR__)

defmodule Omunculus.EvalUsageTest do
  use ExUnit.Case, async: true

  test "mixed providers use each agent's price and preserve cache accounting" do
    config = %{
      agents: %{"coordinator" => %{model: "haiku"}, "worker" => %{model: "local"}},
      models: %{
        "haiku" => %{input: %{"model" => "claude-haiku-5-5"}},
        "local" => %{input: %{"model" => "bonsai2-27b"}}
      }
    }

    facts = %{
      runs: [%{id: "a", agent: "coordinator"}, %{id: "b", agent: "worker"}],
      events: [
        %{
          type: "model",
          run_id: "a",
          body: %{
            "usage" => %{
              "input_tokens" => 100,
              "cache_creation_input_tokens" => 20,
              "cache_read_input_tokens" => 80,
              "output_tokens" => 10
            }
          }
        },
        %{
          type: "model",
          run_id: "b",
          body: %{
            "usage" => %{
              "prompt_tokens" => 300,
              "completion_tokens" => 30,
              "prompt_tokens_details" => %{"cached_tokens" => 250}
            }
          }
        },
        %{
          type: "model",
          run_id: "b",
          body: %{
            "usage" => %{
              "prompt_tokens" => 400,
              "completion_tokens" => 40,
              "cost" => 0.02
            }
          }
        }
      ]
    }

    prices = %{
      "claude-haiku-5-5" => %{
        "input" => 0.10,
        "cache_write" => 0.125,
        "cache_read" => 0.01,
        "output" => 0.50
      }
    }

    usage = EquivalentExchange.Usage.summarize(facts, config, prices)

    assert usage.calls == 3
    assert usage.input_tokens == 900
    assert usage.output_tokens == 80
    assert_in_delta usage.cost, 0.0200183, 1.0e-10
    assert usage.cache.cached_tokens == 330
    assert usage.cache.cache_write_tokens == 20
    assert usage.first_call_cache.prompt_tokens == 500
    assert usage.cache_by_agent["worker"].cached_tokens == 250
  end
end
