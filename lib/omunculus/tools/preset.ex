defmodule Omunculus.Tools.Preset do
  @moduledoc """
  `preset` tool, per spec §9: copies a preset's `omunculus.toml` and
  `tools/` folders into the project root, overwriting what is there.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, roots: roots}) do
    case Args.missing(args, ~w(name)) do
      nil -> apply_preset(roots, args["name"])
      message -> Out.fail(message)
    end
  end

  defp apply_preset(roots, name) do
    preset_dir = Application.app_dir(:omunculus, Path.join("priv/presets", name))

    if File.dir?(preset_dir) do
      copy(hd(roots), preset_dir, name)
    else
      Out.fail("unknown preset: #{name}")
    end
  end

  defp copy(root, preset_dir, name) do
    File.cp!(Path.join(preset_dir, "omunculus.toml"), Path.join(root, "omunculus.toml"))

    tools_dir = Path.join(preset_dir, "tools")

    if File.dir?(tools_dir) do
      File.cp_r!(tools_dir, Path.join(root, "tools"))
    end

    Out.ok(Out.preset_applied(name))
  end
end
