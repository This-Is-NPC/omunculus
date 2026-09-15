defmodule Omunculus.CeilingTest do
  use ExUnit.Case, async: true

  alias Omunculus.Ceiling
  alias Omunculus.Config.Layer

  defp policy(attrs), do: struct(Layer, attrs)

  defp config(attrs),
    do: Map.merge(%{policy: policy(mode: "auto"), depths: %{}, agents: %{}}, attrs)

  defp request(attrs), do: Map.merge(%{agent: "worker", depth: 1, grants: []}, attrs)

  describe "mount/3" do
    test "policy auto alone leaves everything askable" do
      config = config(%{policy: policy(mode: "auto")})

      snapshot = Ceiling.mount(config, request(%{}), ["counter", "write"])

      assert snapshot.askable == ["counter", "write"]
      assert snapshot.have == []
      assert snapshot.sealed == []
      assert snapshot.blocked == []
      assert snapshot.uncited == "askable"
    end

    test "spec §5 example: agent granted list alone gives have under a default auto policy" do
      config =
        config(%{
          agents: %{"worker" => %{depth: 1, text: "", ceiling: policy(granted: ["counter"])}}
        })

      snapshot = Ceiling.mount(config, request(%{}), ["counter"])

      assert snapshot.have == ["counter"]
      assert snapshot.uncited == "askable"
    end

    test "agent allowlist with granted: listed have, rest blocked" do
      config =
        config(%{
          agents: %{
            "worker" => %{
              depth: 1,
              text: "",
              ceiling: policy(mode: "allowlist", granted: ["counter"])
            }
          }
        })

      snapshot = Ceiling.mount(config, request(%{}), ["counter", "write"])

      assert snapshot.have == ["counter"]
      assert snapshot.blocked == ["write"]
      assert snapshot.uncited == "blocked"
    end

    test "agent blocklist (uncited have) intersected with a policy human list: sealed wins" do
      config =
        config(%{
          policy: policy(mode: "auto", human: ["deploy"]),
          agents: %{"worker" => %{depth: 1, text: "", ceiling: policy(mode: "blocklist")}}
        })

      snapshot = Ceiling.mount(config, request(%{}), ["counter", "deploy"])

      assert snapshot.have == ["counter"]
      assert snapshot.sealed == ["deploy"]
      assert snapshot.uncited == "have"
    end

    test "depth deny cuts an agent granted name: blocked wins" do
      config =
        config(%{
          depths: %{1 => policy(mode: "auto", deny: ["counter"])},
          agents: %{
            "worker" => %{
              depth: 1,
              text: "",
              ceiling: policy(mode: "allowlist", granted: ["counter"])
            }
          }
        })

      snapshot = Ceiling.mount(config, request(%{}), ["counter"])

      assert snapshot.blocked == ["counter"]
      assert snapshot.have == []
    end

    test "depth deny cuts a grant of the same name" do
      config = config(%{depths: %{1 => policy(mode: "auto", deny: ["counter"])}})

      snapshot = Ceiling.mount(config, request(%{grants: ["counter"]}), ["counter"])

      assert snapshot.blocked == ["counter"]
      assert snapshot.have == []
    end

    test "grant lifts a sealed name and an askable name" do
      config = config(%{policy: policy(mode: "auto", human: ["deploy"])})

      snapshot =
        Ceiling.mount(config, request(%{grants: ["deploy", "write"]}), ["deploy", "write"])

      assert snapshot.have == ["deploy", "write"]
      assert snapshot.sealed == []
      assert snapshot.askable == []
    end

    test "a path grant not in the catalog appears in have" do
      config = config(%{})

      snapshot = Ceiling.mount(config, request(%{grants: ["./secrets"]}), ["counter"])

      assert "./secrets" in snapshot.have
      assert snapshot.askable == ["counter"]
    end

    test "names cited only in lists, not in the catalog, are still classified" do
      config = config(%{policy: policy(mode: "auto", deny: ["delete"], human: ["deploy"])})

      snapshot = Ceiling.mount(config, request(%{}), ["counter"])

      assert snapshot.askable == ["counter"]
      assert snapshot.blocked == ["delete"]
      assert snapshot.sealed == ["deploy"]
    end
  end

  describe "classify/2" do
    setup do
      config =
        config(%{
          policy:
            policy(
              mode: "allowlist",
              granted: ["counter"],
              negotiable: ["write"],
              human: ["deploy"],
              deny: ["delete"]
            )
        })

      snapshot = Ceiling.mount(config, request(%{}), ["counter", "write"])
      %{snapshot: snapshot}
    end

    test "classifies a have name", %{snapshot: snapshot} do
      assert Ceiling.classify(snapshot, "counter") == "have"
    end

    test "classifies an askable name", %{snapshot: snapshot} do
      assert Ceiling.classify(snapshot, "write") == "askable"
    end

    test "classifies a sealed name", %{snapshot: snapshot} do
      assert Ceiling.classify(snapshot, "deploy") == "sealed"
    end

    test "classifies a blocked name", %{snapshot: snapshot} do
      assert Ceiling.classify(snapshot, "delete") == "blocked"
    end

    test "falls back to uncited for an unlisted name", %{snapshot: snapshot} do
      assert snapshot.uncited == "blocked"
      assert Ceiling.classify(snapshot, "mystery") == "blocked"
    end

    test "accepts a string-keyed snapshot round-tripped through JSON", %{snapshot: snapshot} do
      round_tripped = Jason.decode!(Jason.encode!(snapshot))

      assert Ceiling.classify(round_tripped, "counter") == "have"
      assert Ceiling.classify(round_tripped, "write") == "askable"
      assert Ceiling.classify(round_tripped, "deploy") == "sealed"
      assert Ceiling.classify(round_tripped, "delete") == "blocked"
      assert Ceiling.classify(round_tripped, "mystery") == "blocked"
    end
  end
end
