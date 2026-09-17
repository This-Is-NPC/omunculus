defmodule Omunculus.Tools.Preset do
  @moduledoc """
  `preset` tool: copies `omunculus.toml` and `tools/` from `--from <dir>`
  onto the resolved config path, rewriting `[tools] paths` and
  `execution.sandbox.script` to absolute locations resolved against that
  source directory.
  """

  alias Omunculus.Config.Toml, as: ConfigToml
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, config_path: path}) when is_binary(path) do
    case Args.missing(args, ~w(name from)) do
      nil -> apply_preset(path, args["name"], args["from"])
      message -> Out.fail(message)
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp apply_preset(config_path, name, from) do
    toml = Path.join(from, "omunculus.toml")

    if File.dir?(from) and File.regular?(toml) do
      copy(config_path, from, toml, name)
    else
      Out.fail("unknown preset: #{name}")
    end
  end

  defp copy(config_path, from, toml, name) do
    File.mkdir_p!(Path.dirname(config_path))
    File.cp!(toml, config_path)

    tools_dir = Path.join(from, "tools")

    if File.dir?(tools_dir) do
      File.cp_r!(tools_dir, Path.join(Path.dirname(config_path), "tools"))
    end

    rewrite_paths(config_path, from)
    Out.ok(Out.preset_applied(name))
  end

  defp rewrite_paths(config_path, from) do
    {:ok, data} = Toml.decode_file(config_path)
    dest_tools = Path.join(Path.dirname(config_path), "tools")
    source_paths = get_in(data, ["tools", "paths"]) || []

    paths =
      source_paths
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&expand_from(&1, from))
      |> Enum.concat([dest_tools])
      |> Enum.uniq()

    tools = data |> Map.get("tools", %{}) |> Map.put("paths", paths)

    data
    |> Map.put("tools", tools)
    |> rewrite_sandbox_script(from)
    |> then(&File.write!(config_path, ConfigToml.encode(&1)))
  end

  defp rewrite_sandbox_script(data, from) do
    case get_in(data, ["execution", "sandbox", "script"]) do
      script when is_binary(script) ->
        put_in(data, ["execution", "sandbox", "script"], expand_from(script, from))

      _ ->
        data
    end
  end

  defp expand_from("~" <> _rest = path, _from), do: Path.expand(path)
  defp expand_from(path, from), do: Path.expand(path, from)
end
