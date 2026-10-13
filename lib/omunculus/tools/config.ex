defmodule Omunculus.Tools.Config do
  @moduledoc """
  Builtin `config` tool: the project's setup as a client shows it, in
  JSON. The project root, agents with their depth, model, ceiling lists,
  text and the SHA-256 of their image, if any, the models by name with their api, provider and model id and
  nothing else of their table, the workspaces with their roots and the
  default one, each workflow's steps, and the packs it imports, each with
  its name, folder, depth, the models and logins it is bound to, the
  agents and workflows it brings and the files it holds. Then what an editor needs: the
  items `configure` writes as the file holds them, but a provider's
  literal key, named in `literal_keys`; the file's revision; and the names
  a ceiling list may hold — the model tools, their groups and the sandbox
  resources. That whole setup is what `whole` prints, for a client.

  A model reads it in parts, since a real project's setup outgrows what a
  call may return: without arguments the tool prints an index — the
  file's revision, the root, the default workspace and, for each section,
  the size in bytes of each of its items — `section` prints one section
  whole and `item` one item, `<section>.<name>` or, with `section`, its
  name alone. An agent or workflow item gives what the config runs, the
  pack it comes from and, as `file`, the table the file writes for it; a
  workspace whether it is the default; a provider whether its key is
  literal, in the file. It loads the TOML in the harness's own process,
  since the sandbox hides the file from external tools.
  """

  alias Omunculus.Config
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.{Args, Out}

  @named ~w(agents workflows models workspaces auth secrets packs)
  @single ~w(policy access names)

  @spec run(map) :: map
  def run(%{config_path: path} = input) when is_binary(path) do
    args = Map.get(input, :args) || %{}

    with {:ok, config} <- Config.load(path),
         {:ok, editable} <- Config.document(path),
         whole =
           config
           |> describe()
           |> Map.merge(editable)
           |> Map.put(:names, names(config))
           |> Map.put(:packs, packs(path)),
         {:ok, shown} <- read(whole, args) do
      shown |> Jason.encode!() |> Out.ok()
    else
      {:error, reason} when is_binary(reason) -> Out.fail(reason)
      {:error, reason} -> Out.fail(inspect(reason))
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp read(whole, args) do
    sections = sections(whole)
    section = Args.present(args, "section")
    item = Args.present(args, "item")

    cond do
      Args.flag?(args, "whole") -> {:ok, whole}
      item && section -> read_item(sections, {section, item}, whole.revision)
      item -> read_item(sections, Config.item(item), whole.revision)
      section -> read_section(sections, section, whole.revision)
      true -> {:ok, index(sections, whole)}
    end
  end

  defp index(sections, whole) do
    %{
      revision: whole.revision,
      root: whole.root,
      workspace: whole.workspace,
      sections:
        Map.new(sections, fn
          {name, items} when name in @named ->
            {name, Map.new(items, &{elem(&1, 0), bytes(elem(&1, 1))})}

          {name, part} ->
            {name, bytes(part)}
        end),
      read: "Read a section with section, one item with item (agents.<name>, policy, ...)."
    }
  end

  defp read_section(sections, name, revision) do
    case Map.fetch(sections, name) do
      {:ok, part} -> {:ok, %{section: name, revision: revision, items: part}}
      :error -> {:error, unknown("section #{name}")}
    end
  end

  defp read_item(sections, {section}, revision), do: read_section(sections, section, revision)

  defp read_item(sections, {section, name}, revision) do
    case sections |> Map.get(section) |> lookup(section, name) do
      {:ok, part} -> {:ok, Map.merge(%{item: "#{section}.#{name}", revision: revision}, part)}
      :error -> {:error, unknown("item #{section}.#{name}")}
    end
  end

  defp lookup(items, section, name) when section in @named, do: Map.fetch(items, name)
  defp lookup(_items, _section, _name), do: :error

  defp unknown(what),
    do:
      "no #{what}; the sections are #{Enum.join(@named ++ @single, ", ")}, and config without arguments lists their items"

  defp bytes(part), do: byte_size(Jason.encode!(part))

  # Each section by name: what the config runs, and what the file writes.
  defp sections(whole) do
    file = whole.document

    pack =
      for pack <- whole.packs,
          kind <- [:agents, :workflows],
          name <- Map.fetch!(pack, kind),
          into: %{},
          do: {{kind, name}, pack.name}

    in_file = fn section, name -> get_in(file, [section, name]) end

    %{
      "agents" =>
        Map.new(whole.agents, fn agent ->
          {agent.name,
           agent
           |> Map.drop([:name, :image])
           |> Map.merge(%{pack: pack[{:agents, agent.name}], file: in_file.("agents", agent.name)})}
        end),
      "workflows" =>
        Map.new(whole.workflows, fn workflow ->
          {workflow.name,
           %{
             steps: workflow.steps,
             pack: pack[{:workflows, workflow.name}],
             file: in_file.("workflows", workflow.name)
           }}
        end),
      "models" => tables(file, "models", fn _name -> %{} end),
      "workspaces" =>
        tables(file, "workspaces", fn name -> %{default: name == whole.workspace} end),
      "auth" => tables(file, "auth", fn name -> %{literal_key: name in whole.literal_keys} end),
      "secrets" => tables(file, "secrets", fn _name -> %{} end),
      "packs" => Map.new(whole.packs, &{&1.name, Map.delete(&1, :name)}),
      "policy" => %{file: file["policy"]},
      "access" => %{file: file["access"]},
      "names" => whole.names
    }
  end

  defp tables(file, section, facts) do
    file
    |> Map.get(section, %{})
    |> Map.new(fn {name, table} -> {name, Map.put(facts.(name), :file, table)} end)
  end

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
      text: agent.text,
      image: image(agent.image)
    }
  end

  # An agent's image by its SHA-256, so a client keeps one copy until it changes.
  defp image(nil), do: nil

  defp image(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp model({name, model}) do
    %{name: name, api: model.api, provider: model.input["provider"], model: model.input["model"]}
  end

  defp workflow({name, steps}) do
    %{name: name, steps: Enum.map(steps, &%{name: &1.name, agent: &1.agent})}
  end
end
