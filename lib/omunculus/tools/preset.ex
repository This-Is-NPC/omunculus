defmodule Omunculus.Tools.Preset do
  @moduledoc """
  `preset` tool, per spec §9: copies a preset's `omunculus.toml` onto
  the resolved config path and its `tools/` folder beside that file,
  overwriting what is there.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, config_path: path}) when is_binary(path) do
    case Args.missing(args, ~w(name)) do
      nil -> apply_preset(path, args["name"])
      message -> Out.fail(message)
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp apply_preset(config_path, name) do
    preset_dir = Application.app_dir(:omunculus, Path.join("priv/presets", name))

    if File.dir?(preset_dir) do
      copy(config_path, preset_dir, name)
    else
      Out.fail("unknown preset: #{name}")
    end
  end

  defp copy(config_path, preset_dir, name) do
    File.mkdir_p!(Path.dirname(config_path))
    File.cp!(Path.join(preset_dir, "omunculus.toml"), config_path)

    tools_dir = Path.join(preset_dir, "tools")

    if File.dir?(tools_dir) do
      File.cp_r!(tools_dir, Path.join(Path.dirname(config_path), "tools"))
    end

    Out.ok(Out.preset_applied(name))
  end
end
