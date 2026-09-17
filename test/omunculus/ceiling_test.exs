defmodule Omunculus.CeilingTest do
  use ExUnit.Case, async: true

  alias Omunculus.Ceiling
  alias Omunculus.Config.Layer

  defp policy(attrs), do: struct(Layer, attrs)

  defp config(attrs),
    do: Map.merge(%{policy: policy(mode: "auto"), depths: %{}, agents: %{}}, attrs)

  defp request(attrs),
    do:
      Map.merge(
        %{agent: "worker", depth: 1, grants: [], stage: nil, workspace: nil, groups: %{}},
        attrs
      )

  describe "mount/3" do
    test "sandbox resources use the same ceiling classes as tools" do
      config =
        config(%{
          agents: %{
            "worker" => %{
              depth: 1,
              text: "",
              ceiling: policy(granted: ["sandbox.write"], human: ["sandbox.network"])
            }
          }
        })

      snapshot = Ceiling.mount(config, request(%{}), ["bash", "sandbox.write", "sandbox.network"])

      assert Ceiling.classify(snapshot, "sandbox.write", "resource") == "have"
      assert Ceiling.classify(snapshot, "sandbox.network", "resource") == "sealed"
      assert Ceiling.classify(snapshot, "bash", "tool") == "askable"
    end

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

    test "stage: nil behaves exactly as before" do
      config =
        config(%{
          agents: %{"worker" => %{depth: 1, text: "", ceiling: policy(granted: ["counter"])}}
        })

      snapshot = Ceiling.mount(config, request(%{stage: nil}), ["counter"])

      assert snapshot.have == ["counter"]
      assert snapshot.uncited == "askable"
    end

    test "spec §5 table: a stage deny cuts an agent grant made in the same work" do
      config =
        config(%{
          agents: %{"worker" => %{depth: 1, text: "", ceiling: policy(granted: ["counter"])}}
        })

      to_do = Ceiling.mount(config, request(%{stage: policy(granted: ["counter"])}), ["counter"])
      assert to_do.have == ["counter"]

      review = Ceiling.mount(config, request(%{stage: policy(deny: ["counter"])}), ["counter"])
      assert review.blocked == ["counter"]
      assert review.have == []
    end

    test "a stage deny cuts a work grant of the same name" do
      config = config(%{})

      snapshot =
        Ceiling.mount(config, request(%{grants: ["counter"], stage: policy(deny: ["counter"])}), [
          "counter"
        ])

      assert snapshot.blocked == ["counter"]
      assert snapshot.have == []
    end

    test "a layer without a mode contributes its lists only: an empty stage restricts nothing" do
      config = config(%{agents: %{"worker" => %{ceiling: policy(granted: ["comment"])}}})

      snapshot =
        Ceiling.mount(
          config,
          request(%{agent: "worker", stage: policy([])}),
          ["comment", "write"]
        )

      assert snapshot.have == ["comment"]
      assert snapshot.askable == ["write"]
      assert snapshot.uncited == "askable"
    end

    test "a stage granted list lists a name the agent does not have in its own ceiling" do
      config = config(%{})

      snapshot = Ceiling.mount(config, request(%{stage: policy(granted: ["write"])}), ["write"])

      assert snapshot.have == ["write"]
    end

    test "a workspace deny cuts an agent grant made in the same work" do
      config =
        config(%{
          agents: %{"worker" => %{depth: 1, text: "", ceiling: policy(granted: ["write"])}}
        })

      snapshot =
        Ceiling.mount(config, request(%{workspace: policy(deny: ["write"])}), ["write"])

      assert snapshot.blocked == ["write"]
      assert snapshot.have == []
    end

    test "a workspace grants a name the agent does not have in its own ceiling" do
      config = config(%{})

      snapshot =
        Ceiling.mount(config, request(%{workspace: policy(granted: ["write"])}), ["write"])

      assert snapshot.have == ["write"]
    end
  end

  describe "mount/3 group expansion" do
    test "a granted group name expands to its member names" do
      config =
        config(%{
          agents: %{"worker" => %{depth: 1, text: "", ceiling: policy(granted: ["fs.read"])}}
        })

      snapshot =
        Ceiling.mount(
          config,
          request(%{groups: %{"fs.read" => ["ls", "read"]}}),
          ["read", "ls"]
        )

      assert snapshot.have == ["ls", "read"]
    end

    test "a denied group name blocks its members and cuts a grant of one member" do
      config =
        config(%{
          depths: %{1 => policy(mode: "auto", deny: ["fs.read"])}
        })

      snapshot =
        Ceiling.mount(
          config,
          request(%{grants: ["read"], groups: %{"fs.read" => ["ls", "read"]}}),
          ["read", "ls"]
        )

      assert snapshot.blocked == ["ls", "read"]
      assert snapshot.have == []
    end

    test "a name that matches no group stays a plain name" do
      config =
        config(%{
          agents: %{"worker" => %{depth: 1, text: "", ceiling: policy(granted: ["counter"])}}
        })

      snapshot =
        Ceiling.mount(config, request(%{groups: %{"fs.read" => ["ls", "read"]}}), ["counter"])

      assert snapshot.have == ["counter"]
    end

    test "groups: %{} behaves exactly as before" do
      config =
        config(%{
          agents: %{"worker" => %{depth: 1, text: "", ceiling: policy(granted: ["counter"])}}
        })

      snapshot = Ceiling.mount(config, request(%{groups: %{}}), ["counter"])

      assert snapshot.have == ["counter"]
    end
  end

  describe "mount/3 pinned" do
    test "no layer pinned leaves snapshot.pinned nil" do
      config =
        config(%{
          agents: %{
            "worker" => %{depth: 1, text: "", ceiling: policy(granted: ["comment", "read"])}
          }
        })

      snapshot = Ceiling.mount(config, request(%{agent: "worker"}), ["comment", "read"])
      assert snapshot.pinned == nil
    end

    test "stage pinned intersects agent pinned after group expansion" do
      config =
        config(%{
          agents: %{
            "worker" => %{
              depth: 1,
              text: "",
              ceiling: policy(granted: ["comment", "read", "ls"], pinned: ["store", "fs.read"])
            }
          }
        })

      stage = policy(pinned: ["store"])
      groups = %{"store" => ["comment"], "fs.read" => ["read", "ls"]}

      snapshot =
        Ceiling.mount(
          config,
          request(%{agent: "worker", stage: stage, groups: groups}),
          ["comment", "read", "ls"]
        )

      assert snapshot.pinned == ["comment"]
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
