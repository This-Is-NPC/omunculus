defmodule Omunculus.Ceiling do
  @moduledoc """
  Mounts the effective ceiling of a run from the policy, workspace, depth,
  agent and workflow-step layers of spec §5, and classifies a name against
  a mounted snapshot. Before classifying, every list of every applying
  layer is expanded against the `groups` map of spec §9.5: an entry that
  names a group becomes its member names, any other entry stays as it is.
  A layer's lists always apply; its mode, when it has one, classifies what
  the lists do not cite; the policy mode is the fallback for a name no
  layer classified. The most restrictive class wins.
  """

  alias Omunculus.Config.Layer

  @classes ~w(have askable sealed blocked)

  @spec mount(
          map(),
          %{
            agent: String.t(),
            depth: integer(),
            grants: [String.t()],
            stage: Layer.t() | nil,
            workspace: Layer.t() | nil,
            groups: %{String.t() => [String.t()]}
          },
          [String.t()]
        ) :: %{
          have: [String.t()],
          askable: [String.t()],
          sealed: [String.t()],
          blocked: [String.t()],
          uncited: String.t()
        }
  def mount(
        config,
        %{
          agent: agent_name,
          depth: depth,
          grants: grants,
          stage: stage,
          groups: groups,
          workspace: workspace
        },
        names
      ) do
    layers =
      config
      |> applying_layers(agent_name, depth, stage, workspace)
      |> Enum.map(fn {role, layer} -> {role, expand_layer(layer, groups)} end)

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

  defp applying_layers(config, agent_name, depth, stage, workspace) do
    depth_layer = config |> Map.get(:depths, %{}) |> Map.get(depth)

    agent_layer =
      config |> Map.get(:agents, %{}) |> Map.get(agent_name, %{}) |> Map.get(:ceiling)

    [
      policy: config.policy,
      workspace: workspace,
      depth: depth_layer,
      agent: agent_layer,
      stage: stage
    ]
    |> Enum.reject(fn {_role, layer} -> is_nil(layer) end)
  end

  defp layer_names(%Layer{} = layer) do
    layer.granted ++ layer.negotiable ++ layer.human ++ layer.deny
  end

  defp expand_layer(%Layer{} = layer, groups) do
    %Layer{
      layer
      | granted: expand_list(layer.granted, groups),
        negotiable: expand_list(layer.negotiable, groups),
        human: expand_list(layer.human, groups),
        deny: expand_list(layer.deny, groups)
    }
  end

  defp expand_list(list, groups) do
    list |> Enum.flat_map(&Map.get(groups, &1, [&1])) |> Enum.uniq()
  end

  defp classify_name(layers, policy_mode, name) do
    case Enum.reject(Enum.map(layers, &layer_contribution(&1, name)), &is_nil/1) do
      [] -> mode_default(policy_mode)
      classes -> most_restrictive(classes)
    end
  end

  defp layer_contribution({:policy, layer}, name), do: list_class(layer, name)

  defp layer_contribution({_role, %Layer{mode: mode} = layer}, name) do
    list_class(layer, name) || (mode && mode_default(mode))
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
    layers
    |> Enum.reject(fn {role, %Layer{mode: mode}} -> role == :policy or is_nil(mode) end)
    |> Enum.map(fn {_role, %Layer{mode: mode}} -> mode_default(mode) end)
    |> case do
      [] -> mode_default(policy_mode)
      defaults -> most_restrictive(defaults)
    end
  end

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
