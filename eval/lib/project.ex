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
  pack's workspace files in before the task's.
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
  @spec build(String.t(), String.t(), {String.t(), boolean}, String.t() | nil) ::
          {:ok, String.t()} | {:error, term}
  def build(dir, configuration, {model, code_mode}, workspace) do
    path = Path.join(dir, "omunculus.toml")

    with %{"ok" => true} <-
           Preset.run(%{
             args: %{"name" => "amestris", "from" => Path.join([@eval, "presets", "amestris"])},
             config_path: path
           }),
         {:ok, overlay} <-
           Toml.decode_file(Path.join([@eval, "configs", configuration <> ".toml"])) do
      {eval, overlay} = Map.pop(overlay, "eval", %{})
      packs = Map.get(eval, "packs", [])

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

      with :ok <- import_packs(packs, path, model) do
        if workspace && File.dir?(workspace),
          do: File.cp_r!(workspace, Path.join(dir, "workspace"))

        {:ok, path}
      end
    else
      %{"ok" => false, "output" => reason} -> {:error, {:preset, reason}}
      {:error, _reason} = error -> error
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

  defp import_pack(%{"name" => name} = entry, path, model) do
    dir = Path.join(@packs, name)
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
