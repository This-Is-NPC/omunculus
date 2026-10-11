defmodule Omunculus.Tools.Config do
  @moduledoc """
  Builtin `config` tool: the project's setup as a client shows it, in
  JSON. The project root, agents with their depth, model, ceiling lists
  and text, the models by name with their api, provider and model id and
  nothing else of their table, the workspaces with their roots and the
  default one, each workflow's steps, and the packs it imports, each with
  its name, folder, depth, the models and logins it is bound to, the
  agents and workflows it brings and the files it holds. Then what an editor needs: the
  items `configure` writes as the file holds them, but a provider's
  literal key, named in `literal_keys`; the file's revision; and the names
  a ceiling list may hold — the model tools, their groups and the sandbox
  resources. It loads the TOML in the harness's own
  process, since the sandbox hides the file from external tools.
  """

  alias Omunculus.Config
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{config_path: path}) when is_binary(path) do
    with {:ok, config} <- Config.load(path),
         {:ok, editable} <- Config.document(path) do
      config
      |> describe()
      |> Map.merge(editable)
      |> Map.put(:names, names(config))
      |> Map.put(:packs, packs(path))
      |> Jason.encode!()
      |> Out.ok()
    else
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

  defp packs(path) do
    dir = Path.dirname(Path.expand(path))

    for entry <- Map.get(Toml.decode_file!(path), "packs", []),
        folder = Path.expand(entry["path"], dir),
        {:ok, pack} <- [Config.Packs.read(folder)] do
      %{
        name: pack["pack"]["name"],
        path: folder,
        depth: Map.get(entry, "depth", 0),
        models: Map.get(entry, "models", %{}),
        auth: Map.get(entry, "auth", %{}),
        agents: pack |> Map.get("agents", %{}) |> Map.keys() |> Enum.sort(),
        workflows: pack |> Map.get("workflows", %{}) |> Map.keys() |> Enum.sort(),
        files:
          for(
            file <- Path.wildcard(Path.join(folder, "**/*")),
            File.regular?(file),
            do: Path.relative_to(file, folder)
          )
          |> Enum.sort()
      }
    end
  end

  defp names(config) do
    tools = config.tools |> Catalog.discover() |> Catalog.with_trigger("model")
    groups = tools |> Catalog.groups() |> Map.keys()
    Enum.sort(Enum.uniq(Map.keys(tools) ++ groups ++ Config.known_resources()))
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
      deny: agent.ceiling.deny,
      text: agent.text
    }
  end

  defp model({name, model}) do
    %{name: name, api: model.api, provider: model.input["provider"], model: model.input["model"]}
  end

  defp workflow({name, steps}) do
    %{name: name, steps: Enum.map(steps, &%{name: &1.name, agent: &1.agent})}
  end
end
