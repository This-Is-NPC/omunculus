defmodule Omunculus.EnglishTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.Out

  @accent ~r/[àáâãéêíóôõúçÀÁÂÃÉÊÍÓÔÕÚÇ]/u

  test "builtin manifest descriptions have no accented characters" do
    Enum.each(manifest_paths(), fn path ->
      {:ok, raw} = Toml.decode_file(path)
      description = Map.get(raw, "description", "")

      refute Regex.match?(@accent, description),
             "#{Path.relative_to(path, Application.app_dir(:omunculus))} has accents"
    end)
  end

  test "builtin tool output strings have no accented characters" do
    Enum.each(Out.user_facing(), fn string ->
      refute Regex.match?(@accent, string), string
    end)
  end

  defp manifest_paths do
    for root <- ["priv/tools", "priv/presets"],
        path <- Path.wildcard(Path.join([Application.app_dir(:omunculus), root, "**", "*.toml"])),
        Path.basename(path) in ["tool.toml", "hook.toml"] do
      path
    end
  end
end
