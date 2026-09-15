defmodule Omunculus.Ceiling do
  @moduledoc """
  Mounts the effective ceiling of a run from the policy, depth, and agent
  layers of spec §5, and classifies a name against a mounted snapshot.
  """

  alias Omunculus.Config.Layer

  @classes ~w(have askable sealed blocked)

  @spec mount(map(), %{agent: String.t(), depth: integer(), grants: [String.t()]}, [
          String.t()
        ]) :: %{
          have: [String.t()],
          askable: [String.t()],
          sealed: [String.t()],
          blocked: [String.t()],
          uncited: String.t()
        }
  def mount(config, %{agent: agent_name, depth: depth, grants: grants}, names) do
    layers = applying_layers(config, agent_name, depth)
    policy_mode = config.policy.mode

    cited = layers |> Enum.map(fn {_role, layer} -> layer end) |> Enum.flat_map(&layer_names/1)
    all_names = Enum.uniq(names ++ cited ++ grants)

    classes =
      for name <- all_names, into: %{} do
        {name, classify_name(layers, policy_mode, name)}
      end
      |> apply_grants(grants)

    group(classes, uncited(layers, policy_mode))
  end

  @spec classify(map(), String.t()) :: String.t()
  def classify(snapshot, name) do
    snapshot = normalize(snapshot)

    Enum.find(@classes, snapshot.uncited, fn class ->
      name in Map.fetch!(snapshot, String.to_existing_atom(class))
    end)
  end

  defp applying_layers(config, agent_name, depth) do
    depth_layer = config |> Map.get(:depths, %{}) |> Map.get(depth)

    agent_layer =
      config |> Map.get(:agents, %{}) |> Map.get(agent_name, %{}) |> Map.get(:ceiling)

    [policy: config.policy, depth: depth_layer, agent: agent_layer]
    |> Enum.reject(fn {_role, layer} -> is_nil(layer) end)
  end

  defp layer_names(%Layer{} = layer) do
    layer.granted ++ layer.negotiable ++ layer.human ++ layer.deny
  end

  # The policy layer contributes only what its own lists cite: an uncited
  # name never falls back to the policy mode by itself, only via a depth or
  # agent layer whose own mode is nil (see `effective_mode/2`). This keeps a
  # bare `[policy] mode = "auto"` from overriding an explicit grant made at
  # a more specific layer (spec §5, "Stage e grant no mesmo work" example).
  defp classify_name(layers, policy_mode, name) do
    contributions =
      layers
      |> Enum.map(fn {role, layer} -> layer_contribution(role, layer, policy_mode, name) end)
      |> Enum.reject(&is_nil/1)

    case contributions do
      [] -> mode_default(policy_mode)
      classes -> most_restrictive(classes)
    end
  end

  defp layer_contribution(:policy, layer, _policy_mode, name), do: list_class(layer, name)

  defp layer_contribution(_role, layer, policy_mode, name) do
    list_class(layer, name) || mode_default(effective_mode(layer, policy_mode))
  end

  defp list_class(%Layer{} = layer, name) do
    cond do
      name in layer.deny -> "blocked"
      name in layer.human -> "sealed"
      name in layer.negotiable -> "askable"
      name in layer.granted -> "have"
      true -> nil
    end
  end

  defp uncited(layers, policy_mode) do
    non_policy_defaults =
      layers
      |> Enum.reject(fn {role, _layer} -> role == :policy end)
      |> Enum.map(fn {_role, layer} -> mode_default(effective_mode(layer, policy_mode)) end)

    case non_policy_defaults do
      [] -> mode_default(policy_mode)
      defaults -> most_restrictive(defaults)
    end
  end

  defp effective_mode(%Layer{mode: nil}, policy_mode), do: policy_mode
  defp effective_mode(%Layer{mode: mode}, _policy_mode), do: mode

  defp mode_default("allowlist"), do: "blocked"
  defp mode_default("blocklist"), do: "have"
  defp mode_default("auto"), do: "askable"

  defp apply_grants(classes, grants) do
    Enum.reduce(grants, classes, fn name, acc ->
      if Map.get(acc, name) == "blocked" do
        acc
      else
        Map.put(acc, name, "have")
      end
    end)
  end

  defp most_restrictive(classes), do: Enum.max_by(classes, &rank/1)

  defp rank("blocked"), do: 4
  defp rank("sealed"), do: 3
  defp rank("askable"), do: 2
  defp rank("have"), do: 1

  defp group(classes, uncited) do
    grouped =
      Enum.group_by(classes, fn {_name, class} -> class end, fn {name, _class} -> name end)

    %{
      have: grouped |> Map.get("have", []) |> Enum.sort(),
      askable: grouped |> Map.get("askable", []) |> Enum.sort(),
      sealed: grouped |> Map.get("sealed", []) |> Enum.sort(),
      blocked: grouped |> Map.get("blocked", []) |> Enum.sort(),
      uncited: uncited
    }
  end

  defp normalize(snapshot) do
    %{
      have: fetch(snapshot, :have),
      askable: fetch(snapshot, :askable),
      sealed: fetch(snapshot, :sealed),
      blocked: fetch(snapshot, :blocked),
      uncited: fetch(snapshot, :uncited)
    }
  end

  defp fetch(snapshot, key) do
    Map.get(snapshot, key) || Map.get(snapshot, Atom.to_string(key))
  end
end
