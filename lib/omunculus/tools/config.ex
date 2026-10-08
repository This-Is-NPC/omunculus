defmodule Omunculus.Tools.Config do
  @moduledoc """
  Builtin `config` tool: the project's setup as a client shows it, in
  JSON. The project root, agents with their depth, model and ceiling
  lists, the models by name with their api, provider and model id and
  nothing else of their table, the workspaces with their roots and the
  default one, and each workflow's steps. It loads the TOML in the harness's own process, since
  the sandbox hides the file from external tools.
  """

  alias Omunculus.Config
  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{config_path: path}) when is_binary(path) do
    case Config.load(path) do
      {:ok, config} -> config |> describe() |> Jason.encode!() |> Out.ok()
      {:error, reason} -> Out.fail(inspect(reason))
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp describe(config) do
    %{
      root: config.root,
      agents:
        config.agents
        |> Enum.sort_by(fn {name, agent} -> {agent.depth, name} end)
        |> Enum.map(&agent/1),
      models: config.models |> Enum.sort() |> Enum.map(&model/1),
      workspaces:
        config.workspaces
        |> Enum.sort()
        |> Enum.map(fn {name, workspace} -> %{name: name, root: workspace.root} end),
      workspace: config.policy_workspace,
      workflows: config.workflows |> Enum.sort() |> Enum.map(&workflow/1)
    }
  end

  defp agent({name, agent}) do
    %{
      name: name,
      depth: agent.depth,
      model: agent.model,
      workflow_only: agent.workflow_only,
      granted: agent.ceiling.granted,
      negotiable: agent.ceiling.negotiable,
      human: agent.ceiling.human,
      deny: agent.ceiling.deny
    }
  end

  defp model({name, model}) do
    %{name: name, api: model.api, provider: model.input["provider"], model: model.input["model"]}
  end

  defp workflow({name, steps}) do
    %{name: name, steps: Enum.map(steps, &%{name: &1.name, agent: &1.agent})}
  end
end
