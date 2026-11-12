defmodule EquivalentExchange.Project do
  @moduledoc """
  Builds the project one execution runs in: the Amestris preset applied by
  omunculus's own `preset` tool, the configuration of `eval/configs` laid
  over it — its tables merged into the preset's, a list replacing a list — the
  agents its `[eval] drop_agents` names removed with the workflows that
  needed them, every agent put on the model the run names — with
  `code_mode` on when the run asks for it —, the bench's skills
  (`eval/skills`) and ticket system (`eval/mcp/tickets`, an MCP server)
  declared, and the task's starting files copied into the workspace. A
  configuration whose `[eval] packs` lists packs of `packs/` — each a `name`
  and the `depth` its team works below its own — runs those teams alone:
  Amestris's agents and workflows go, and omunculus's own `pack` tool
  imports each, in order, every role on the run's model and each provider
  the pack names on the configuration's login of that name, copying the
  pack's workspace files in before the task's. Such a configuration's own
  `workflows`, `[policy.depth.<n>]` layers and `[[interceptors]]` compose the teams — a workflow whose stages are
  agents of different packs — so they are laid over the
  project once the packs are imported, and it must load then.
  Per-agent model overrides are applied after those imports and validated
  against the expanded agents and available model aliases.
  """

  alias Omunculus.Config.Toml, as: ConfigToml
  alias Omunculus.Tools.Preset

  @eval Path.expand("..", __DIR__)
  @packs Path.expand("../../packs", __DIR__)

  @spec configurations() :: [String.t()]
  def configurations do
    Path.join([@eval, "configs", "*.toml"])
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".toml"))
    |> Enum.sort()
  end

  @doc "Builds the project in `dir` and returns the path of its omunculus.toml."
  @spec build(
          String.t(),
          String.t(),
          {String.t(), boolean},
          String.t() | nil,
          map,
          String.t() | nil
        ) ::
          {:ok, String.t()} | {:error, term}
  def build(
        dir,
        configuration,
        {model, code_mode},
        workspace,
        agent_models \\ %{},
        overlay_path \\ nil
      ) do
    path = Path.join(dir, "omunculus.toml")

    with %{"ok" => true} <-
           Preset.run(%{
             args: %{"name" => "amestris", "from" => Path.join([@eval, "presets", "amestris"])},
             config_path: path
           }),
         {:ok, overlay} <- configuration(configuration, overlay_path) do
      {eval, overlay} = Map.pop(overlay, "eval", %{})
      packs = Map.get(eval, "packs", []) ++ Map.get(eval, "extra_packs", [])
      {composition, overlay} = if packs == [], do: {%{}, overlay}, else: composition(overlay)

      data =
        path
        |> Toml.decode_file!()
        |> merge(overlay)
        |> Map.update!("agents", &Map.drop(&1, Map.get(eval, "drop_agents", [])))
        |> then(
          &if(packs != [], do: Map.merge(&1, %{"agents" => %{}, "workflows" => %{}}), else: &1)
        )
        |> Map.update!("agents", fn agents ->
          Map.new(agents, fn {name, agent} -> {name, Map.put(agent, "model", model)} end)
        end)
        |> then(&if(code_mode, do: put_in(&1, ["models", model, "code_mode"], true), else: &1))
        |> drop_orphan_workflows()
        |> Map.put("project", %{"root" => "workspace"})
        |> Map.put("skills", %{"paths" => [Path.join(@eval, "skills")]})
        |> Map.put("mcp", %{"servers" => [tickets()]})

      File.write!(path, ConfigToml.encode(data))
      File.mkdir_p!(Path.join(dir, "workspace"))

      with :ok <- import_packs(packs, path, model),
           :ok <- compose(path, composition),
           :ok <- adapt_agents(path, eval),
           :ok <- single_agent(path, Map.get(eval, "single_agent")),
           :ok <- assign_models(path, agent_models, code_mode) do
        if workspace && File.dir?(workspace),
          do: File.cp_r!(workspace, Path.join(dir, "workspace"))

        {:ok, path}
      end
    else
      %{"ok" => false, "output" => reason} -> {:error, {:preset, reason}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Loads an eval configuration with an optional experimental TOML overlay."
  def configuration(name, overlay_path \\ nil) do
    with {:ok, base} <- Toml.decode_file(Path.join([@eval, "configs", name <> ".toml"])) do
      if overlay_path do
        with {:ok, extra} <- Toml.decode_file(overlay_path), do: {:ok, merge(base, extra)}
      else
        {:ok, base}
      end
    end
  end

  defp adapt_agents(path, eval) do
    {:ok, config} = Omunculus.Config.load(path)
    data = Toml.decode_file!(path)

    agents =
      Enum.reduce(Map.get(eval, "agent_overrides", %{}), data["agents"], fn {name, override},
                                                                            agents ->
        original = Map.fetch!(config.agents, name)
        {append, override} = Map.pop(override, "append_text")

        override =
          if append,
            do: Map.put(override, "text", original.text <> "\n\n" <> append),
            else: override

        Map.put(agents, name, Map.merge(Map.get(agents, name, %{}), override))
      end)

    data = Map.put(data, "agents", agents)
    extra_paths = Enum.map(Map.get(eval, "tool_paths", []), &Path.expand(&1, @eval))
    data = update_in(data, ["tools", "paths"], &((&1 || []) ++ extra_paths))
    File.write!(path, ConfigToml.encode(data))
    :ok
  end

  # What a work tree is made of: handing work down, answering it up and
  # asking along the way. A lone agent has no one to do either with.
  @delegating ~w(work delegate continue break wait done cancel ask escalate forward reopen retire grant deliver start_sale start_design start_build next_stage wait_client)

  @doc "The tools a lone agent stands in for the work tree with: no tool that delegates."
  @spec single_tools([[String.t()]]) :: [String.t()]
  def single_tools(lists) do
    lists
    |> List.flatten()
    |> Enum.map(&if(&1 == "sequence", do: "end", else: &1))
    |> Enum.reject(&(&1 in @delegating))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # `[eval.single_agent]` collapses the hierarchy into the agent that
  # receives the person's messages: it holds every tool the agents had
  # together, minus those that delegate, and the `text` the table gives;
  # the workflows, depth layers and interceptors that named agents go. The
  # packs are laid out first, so the team's agents are among those merged.
  defp single_agent(_path, nil), do: :ok

  defp single_agent(path, %{"text" => text}) do
    {:ok, data, _required} =
      path |> Toml.decode_file!() |> Omunculus.Config.Packs.expand(Path.dirname(path))

    entry = entry_agent(data)

    tools =
      data["agents"] |> Map.values() |> Enum.map(&Map.get(&1, "tools", [])) |> single_tools()

    agent =
      data["agents"]
      |> Map.fetch!(entry)
      |> Map.drop(["negotiable"])
      |> Map.merge(%{"tools" => tools, "text" => text})

    data =
      data
      |> Map.put("agents", %{entry => agent})
      |> Map.put("workflows", %{})
      |> Map.update(
        "interceptors",
        [],
        &Enum.reject(&1, fn each -> Map.has_key?(each, "workflow") end)
      )
      |> Map.update("policy", %{}, &Map.drop(&1, ["depth"]))
      |> put_in(["policy", "default_agent"], entry)

    File.write!(path, ConfigToml.encode(data))

    case Omunculus.Config.load(path) do
      {:ok, _config} -> :ok
      {:error, reason} -> {:error, {:single_agent, reason}}
    end
  end

  # The agent that receives each message of the person.
  defp entry_agent(data) do
    top = for {name, %{"depth" => 0}} <- data["agents"], do: name

    case {get_in(data, ["policy", "default_agent"]), top} do
      {name, _top} when is_binary(name) -> name
      {nil, [name]} -> name
    end
  end

  defp assign_models(path, agent_models, code_mode) do
    data = Toml.decode_file!(path)
    {:ok, config} = Omunculus.Config.load(path)

    invalid =
      Enum.find(agent_models, fn {agent, model} ->
        not Map.has_key?(config.agents, agent) or not Map.has_key?(config.models, model)
      end)

    if invalid do
      {:error, {:agent_model, invalid}}
    else
      data =
        Enum.reduce(agent_models, data, fn {agent, model}, data ->
          data =
            update_in(data, ["agents"], fn agents ->
              Map.update(agents, agent, %{"model" => model}, &Map.put(&1, "model", model))
            end)

          if code_mode, do: put_in(data, ["models", model, "code_mode"], true), else: data
        end)

      File.write!(path, ConfigToml.encode(data))

      case Omunculus.Config.load(path) do
        {:ok, _config} -> :ok
        {:error, reason} -> {:error, {:agent_model, reason}}
      end
    end
  end

  defp import_packs(packs, path, model) do
    Enum.reduce_while(packs, :ok, fn pack, :ok ->
      case import_pack(pack, path, model) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp import_pack(entry, path, model) do
    dir =
      if entry["path"],
        do: Path.expand(entry["path"], @eval),
        else: Path.join(@packs, entry["name"])

    {:ok, pack} = Omunculus.Config.Packs.read(dir)
    pairs = fn names, to -> Enum.map_join(names || [], ",", &"#{&1}=#{to.(&1)}") end

    case Omunculus.Tools.Pack.run(%{
           args: %{
             "path" => dir,
             "models" => pairs.(pack["pack"]["roles"], fn _role -> model end),
             "auth" => pairs.(pack["pack"]["auth"], & &1),
             "depth" => to_string(Map.get(entry, "depth", 0))
           },
           config_path: path
         }) do
      %{"ok" => true} -> :ok
      %{"output" => output} -> {:error, {:pack, output}}
    end
  end

  # What composes the teams of the packs: it names their agents and
  # workflows, so it is laid over the project only once they are imported.
  defp composition(overlay) do
    {workflows, overlay} = Map.pop(overlay, "workflows")
    {interceptors, overlay} = Map.pop(overlay, "interceptors")
    {layers, policy} = Map.split(Map.get(overlay, "policy", %{}), ["depth"])

    composition =
      %{
        "workflows" => workflows,
        "policy" => if(layers != %{}, do: layers),
        "interceptors" => interceptors,
        "accounts" => if(interceptors, do: %{"owner" => owner()})
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    {composition, Map.put(overlay, "policy", policy)}
  end

  # The eval's one person is client and owner: the user running it, who
  # answers the reviews the configurations' interceptors name `owner`.
  defp owner do
    %{issuer: issuer, subject: subject} = Omunculus.Operations.local_principal()
    %{"kind" => "human", "issuer" => issuer, "subject" => subject}
  end

  defp compose(_path, composition) when composition == %{}, do: :ok

  defp compose(path, composition) do
    File.write!(path, path |> Toml.decode_file!() |> merge(composition) |> ConfigToml.encode())

    case Omunculus.Config.load(path) do
      {:ok, _config} -> :ok
      {:error, reason} -> {:error, {:compose, reason}}
    end
  end

  # The bench's ticket system: the MCP server whose data no workspace has.
  defp tickets,
    do: %{
      "name" => "tickets",
      "command" => [Path.join([@eval, "mcp", "tickets"])],
      "protocol_version" => "2025-03-26"
    }

  # A workflow one of whose stages names an agent no longer there goes too.
  defp drop_orphan_workflows(data) do
    agents = Map.keys(data["agents"])
    workflows = Map.get(data, "workflows", %{})

    kept =
      Map.filter(workflows, fn {_name, workflow} ->
        Enum.all?(workflow["steps"], &(&1["agent"] in agents))
      end)

    Map.put(data, "workflows", kept)
  end

  defp merge(left, right) when is_map(left) and is_map(right),
    do: Map.merge(left, right, fn _key, a, b -> merge(a, b) end)

  defp merge(_left, right), do: right
end
