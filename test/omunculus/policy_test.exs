defmodule Omunculus.PolicyTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Config, Policy}

  @fixture Path.expand("../fixtures/config/simple.toml", __DIR__)

  test "normalize allow with deny delegate forbids delegate and grants the rest" do
    assert {:ok, bands} =
             Policy.normalize(%{
               "mode" => "allow",
               "deny" => ["delegate"]
             })

    assert "delegate" in bands["forbidden"]
    refute "delegate" in bands["granted"]
    assert "read" in bands["granted"]
    assert "write" in bands["granted"]
    assert bands["negotiable"] == []
    assert bands["human"] == []
  end

  test "normalize deny with granted counter only grants counter" do
    assert {:ok, bands} =
             Policy.normalize(%{
               "mode" => "deny",
               "granted" => ["counter"]
             })

    assert bands["granted"] == ["counter"]
    assert "write" in bands["forbidden"]
    assert "read" in bands["forbidden"]
    assert bands["negotiable"] == []
    assert bands["human"] == []
  end

  test "intersect moves granted intersect forbidden to forbidden" do
    a = %{"granted" => ["read"], "negotiable" => [], "human" => [], "forbidden" => []}
    b = %{"granted" => [], "negotiable" => [], "human" => [], "forbidden" => ["read"]}

    assert Policy.intersect(a, b)["forbidden"] == ["read"]
    assert Policy.intersect(a, b)["granted"] == []
  end

  test "table for empty config uses default synthetic workspace" do
    table = Policy.table(Config.empty())

    assert {:ok, _bands} = Policy.line(table, "coding", "0", "default")
    refute Map.has_key?(table, {"coding", "0", "app"})
  end

  test "table for simple.toml count depth 0 app grants counter not write" do
    assert {:ok, config} = Config.load(cwd: Path.dirname(@fixture), config_file: @fixture)
    table = Policy.table(config)

    assert {:ok, bands} = Policy.line(table, "count", "0", "app")
    assert "counter" in bands["granted"]
    refute "write" in bands["granted"]
    assert "write" in bands["forbidden"]
  end

  test "hash is stable across two table calls" do
    assert {:ok, config} = Config.load(cwd: Path.dirname(@fixture), config_file: @fixture)

    table1 = Policy.table(config)
    table2 = Policy.table(config)

    assert Policy.hash(table1) == Policy.hash(table2)
    assert is_binary(Policy.hash(table1))
  end

  test "narrow outside granted returns error" do
    bands = %{
      "granted" => ["read", "grep"],
      "negotiable" => [],
      "human" => [],
      "forbidden" => ["write"]
    }

    assert {:error, {:tools_flag_outside_granted, "write"}} =
             Policy.narrow(bands, ["read", "write"])
  end

  test "fits_ceiling? is false when profile grants edit and ceiling forbids it" do
    profile = %{
      "granted" => ["read", "edit"],
      "negotiable" => [],
      "human" => [],
      "forbidden" => []
    }

    ceiling = %{
      "granted" => ["read"],
      "negotiable" => [],
      "human" => [],
      "forbidden" => ["edit"]
    }

    refute Policy.fits_ceiling?(profile, ceiling)
    assert Policy.fits_ceiling?(%{profile | "granted" => ["read"]}, ceiling)
  end

  test "authority is granted union negotiable" do
    bands = %{
      "granted" => ["read"],
      "negotiable" => ["edit"],
      "human" => [],
      "forbidden" => ["write"]
    }

    assert MapSet.equal?(Policy.authority(bands), MapSet.new(["read", "edit"]))
  end

  test "line returns error for unknown combination" do
    table = %{
      {"coding", "0", "app"} => %{
        "granted" => [],
        "negotiable" => [],
        "human" => [],
        "forbidden" => []
      }
    }

    assert {:error, {:no_policy_line, "missing", "0", "app"}} =
             Policy.line(table, "missing", "0", "app")
  end
end
