defmodule Omunculus.Tools.Overview do
  @moduledoc """
  Builtin `overview` tool: the project as it runs in each place a work can
  run, in JSON, for a client to draw. A place is a workspace, or the
  project root while no workspace is the default. For each place: its
  folder, whether it is the default or outside the project, its own
  ceiling lists and what it overlays; then each depth as the config reads
  there — its workflow, whether the place changed it, the stages with
  their `deny` and their agent, and the agents a work can go to without a
  stage. An agent comes with its model (id, api, `body`, whether the place
  changed it), where its provider's key comes from, and the names its
  layer lists, each classified by the run's ceiling there (`have`,
  `askable`, `sealed`, `blocked`), a group with its members, a tool with
  the secrets the config binds to it. Workflows no place runs are listed
  apart. It loads the TOML in the harness's process.
  """

  alias Omunculus.{Ceiling, Config}
  alias Omunculus.Path, as: FilesystemPath
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{config_path: path}) when is_binary(path) do
    case Config.load(path) do
      {:ok, config} -> config |> overview() |> Jason.encode!() |> Out.ok()
      {:error, reason} -> Out.fail(inspect(reason))
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp overview(config) do
    groups = config.tools |> Catalog.discover() |> Catalog.groups()

    places =
      for name <- places(config), {:ok, here} <- [Config.for_workspace(config, name)] do
        place(config, here, name, groups)
      end

    run = places |> Enum.flat_map(& &1.depths) |> Enum.map(& &1.workflow) |> MapSet.new()

    %{
      root: config.root,
      places: places,
      unused_workflows: config.workflows |> Map.keys() |> Enum.reject(&(&1 in run)) |> Enum.sort()
    }
  end

  # Without a default workspace a work that names none runs in the root.
  defp places(config) do
    names = config.workspaces |> Map.keys() |> Enum.sort()
    if config.policy_workspace, do: names, else: [nil | names]
  end

  defp place(base, here, name, groups) do
    workspace = name && Map.fetch!(base.workspaces, name)
    layer = workspace && workspace.ceiling

    %{
      workspace: name,
      root: if(workspace, do: workspace.root, else: base.root),
      default: name != nil and name == base.policy_workspace,
      outside: workspace != nil and not FilesystemPath.within?(base.root, workspace.root),
      layer: layer && lists(layer),
      changes: if(workspace, do: changes(workspace), else: []),
      depths:
        here.agents
        |> Map.values()
        |> Enum.map(& &1.depth)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&depth(base, here, layer, &1, groups))
    }
  end

  defp changes(workspace) do
    overlaid = workspace.overlay |> Map.keys() |> Enum.sort()
    if workspace.config, do: overlaid ++ ["config file"], else: overlaid
  end

  defp depth(base, here, layer, depth, groups) do
    workflow = Config.workflow_name_for(here, depth)
    steps = if workflow, do: Map.fetch!(here.workflows, workflow), else: []
    staged = Enum.map(steps, & &1.agent)

    %{
      depth: depth,
      workflow: workflow,
      changed: workflow != Config.workflow_name_for(base, depth),
      stages:
        Enum.map(steps, fn step ->
          %{
            name: step.name,
            deny: step.ceiling.deny,
            agent: agent(base, here, layer, step.agent, depth, step.ceiling, groups)
          }
        end),
      agents:
        here.agents
        |> Enum.filter(fn {name, agent} -> agent.depth == depth and name not in staged end)
        |> Enum.sort_by(fn {name, _agent} -> name end)
        |> Enum.map(fn {name, _agent} ->
          agent(base, here, layer, name, depth, nil, groups)
          # A workflow-only agent runs in no stage of this depth here.
          |> then(&Map.put(&1, :idle, &1.workflow_only))
        end)
    }
  end

  defp agent(base, here, layer, name, depth, stage, groups) do
    agent = Map.fetch!(here.agents, name)
    model = Map.fetch!(here.models, agent.model)
    base_model = base.agents |> Map.get(name, %{}) |> Map.get(:model)

    context = %{
      agent: name,
      depth: depth,
      grants: [],
      stage: stage,
      groups: groups,
      workspace: layer
    }

    listed = layer_names(agent.ceiling) ++ ((layer && layer.human) || [])
    snapshot = Ceiling.mount(here, context, listed)

    %{
      name: name,
      workflow_only: agent.workflow_only,
      idle: false,
      model: %{
        name: agent.model,
        id: model.input["model"] || model.input["module"],
        api: model.api,
        body: model.input["body"] || %{},
        provider: model.input["provider"],
        changed: agent.model != base_model
      },
      key: key(here, model.input["provider"]),
      tools: listed |> Enum.uniq() |> Enum.map(&tool(here, snapshot, &1, groups))
    }
  end

  defp layer_names(layer), do: layer.granted ++ layer.negotiable ++ layer.human

  defp tool(config, snapshot, name, groups) do
    members = Map.get(groups, name)

    %{
      name: name,
      state:
        if(members, do: group_state(snapshot, members), else: Ceiling.classify(snapshot, name)),
      members: members,
      secrets: Map.get(config.secrets, name, %{})
    }
  end

  # A group reads as the best its members have here.
  defp group_state(snapshot, members) do
    states = Enum.map(members, &Ceiling.classify(snapshot, &1))
    Enum.find(~w(have askable sealed blocked), "blocked", &(&1 in states))
  end

  defp key(_config, nil), do: nil

  defp key(config, provider) do
    %{provider: provider, source: source(Map.get(config.auth.providers, provider))}
  end

  # Where a provider's key comes from; never the key.
  defp source(nil), do: "not configured"
  defp source(%{kind: "api_key", key: "$" <> variable}), do: "$" <> variable

  defp source(%{kind: "api_key", key: "!" <> command}) do
    case Regex.run(~r/omapass'? get -- '?([^']+)'?$/, command) do
      [_, account] -> "omapass · " <> account
      nil -> "command"
    end
  end

  defp source(%{kind: "api_key", key: key}) when key in [nil, ""], do: "stored login"
  defp source(%{kind: "api_key"}), do: "in the file"
  defp source(%{kind: _login}), do: "stored login"

  defp lists(layer) do
    %{
      mode: layer.mode,
      has: layer.granted,
      negotiable: layer.negotiable,
      human: layer.human,
      deny: layer.deny
    }
  end
end
