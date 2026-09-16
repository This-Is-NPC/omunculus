defmodule Omunculus.Config.TomlTest do
  use ExUnit.Case, async: true

  alias Omunculus.Config.Toml, as: ConfigToml

  test "empty map encodes to an empty string" do
    assert ConfigToml.encode(%{}) == ""
  end

  test "round-trips a config-shaped map" do
    map = %{
      "execution" => %{
        "backend" => "bubblewrap",
        "runtimes" => ["/usr"],
        "environment" => ["LANG"],
        "timeout_ms" => 30_000,
        "max_output_bytes" => 1_048_576,
        "max_concurrent" => 4,
        "max_queue" => 64,
        "queue_timeout_ms" => 30_000
      },
      "policy" => %{
        "mode" => "auto",
        "depth" => %{
          "1" => %{
            "mode" => "allowlist",
            "granted" => ["counter", "write"]
          }
        }
      },
      "agents" => %{
        "concierge" => %{
          "depth" => 0,
          "granted" => ["comment", "request_access", "work"],
          "text" => "line one\nline two"
        }
      }
    }

    assert Toml.decode!(ConfigToml.encode(map)) == map
  end

  test "bare keys are not quoted" do
    encoded = ConfigToml.encode(%{"agent-name_1" => "value"})
    assert encoded == ~s(agent-name_1 = "value")
  end

  test "keys that are not bare are quoted" do
    encoded = ConfigToml.encode(%{"has space" => "value"})
    assert encoded == ~s("has space" = "value")
  end

  test "booleans and integers are encoded without quotes" do
    encoded = ConfigToml.encode(%{"on" => true, "count" => 3})
    assert Toml.decode!(encoded) == %{"on" => true, "count" => 3}
  end

  test "a list of maps round-trips as a list of inline tables" do
    map = %{
      "workflows" => %{
        "delivery" => %{
          "steps" => [
            %{"name" => "to_do", "agent" => "worker"},
            %{"name" => "review", "agent" => "concierge", "deny" => ["counter"]}
          ]
        }
      }
    }

    encoded = ConfigToml.encode(map)
    assert encoded =~ ~s({ agent = "worker", name = "to_do" })
    assert Toml.decode!(encoded) == map
  end
end
