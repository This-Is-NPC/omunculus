defmodule EquivalentExchange.Project do
  @moduledoc """
  Builds the project one execution runs in: the Amestris preset applied by
  omunculus's own `preset` tool, a configuration of `eval/configs` laid over
  it — its tables merged into the preset's, a list replacing a list — the
  agents its `[eval] drop_agents` names removed with the workflows that
  needed them, every agent put on the model the run names — with
  `code_mode` on when the run asks for it — and the task's starting files
  copied into the project root.
  """

  alias Omunculus.Config.Toml, as: ConfigToml
  alias Omunculus.Tools.Preset

  @eval Path.expand("..", __DIR__)

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

      data =
        path
        |> Toml.decode_file!()
        |> merge(overlay)
        |> Map.update!("agents", &Map.drop(&1, Map.get(eval, "drop_agents", [])))
        |> Map.update!("agents", fn agents ->
          Map.new(agents, fn {name, agent} -> {name, Map.put(agent, "model", model)} end)
        end)
        |> then(&if(code_mode, do: put_in(&1, ["models", model, "code_mode"], true), else: &1))
        |> drop_orphan_workflows()
        |> Map.put("project", %{"root" => "workspace"})

      File.write!(path, ConfigToml.encode(data))
      root = Path.join(dir, "workspace")
      File.mkdir_p!(root)
      if workspace && File.dir?(workspace), do: File.cp_r!(workspace, root)
      {:ok, path}
    else
      %{"ok" => false, "output" => reason} -> {:error, {:preset, reason}}
      {:error, _reason} = error -> error
    end
  end

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
