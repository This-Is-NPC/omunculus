defmodule Omunculus.Tools.Skill do
  @moduledoc """
  Builtin `skill` tool: reads one of the skills the run has, from the
  `skills` view. Without `file`, its `SKILL.md` and the files of its
  folder; with `file`, that file, which must lie inside the folder. It
  reads in the harness's process, since a skill's folder is outside the
  sandbox.
  """

  alias Omunculus.Path, as: FilesystemPath
  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{args: %{"name" => name} = args, view: view}) when is_binary(name) do
    case Enum.find(view["skills"] || [], &(&1.name == name)) do
      nil -> Out.fail("no skill #{name} in this run")
      skill -> read(skill, args["file"])
    end
  end

  def run(_input), do: Out.fail("name required")

  defp read(skill, nil) do
    with {:ok, text} <- File.read(Path.join(skill.dir, "SKILL.md")) do
      files = files(skill.dir) -- ["SKILL.md"]

      listing =
        if files == [],
          do: "",
          else: "\n\n## Files\n" <> Enum.map_join(files, "\n", &("- " <> &1))

      Out.ok(text <> listing)
    else
      {:error, reason} -> Out.fail("#{skill.name}: #{:file.format_error(reason)}")
    end
  end

  # Through links resolved, so none leads out of the folder.
  defp read(skill, file) when is_binary(file) do
    with {:ok, root} <- FilesystemPath.canonical(skill.dir),
         {:ok, path} <- FilesystemPath.canonical(Path.expand(file, skill.dir)),
         true <- FilesystemPath.within?(root, path) do
      if File.regular?(path),
        do: Out.ok(File.read!(path)),
        else: Out.fail("#{skill.name} has no file #{file}")
    else
      _outside -> Out.fail("#{file} is outside the skill")
    end
  end

  # Every file below the folder, by its path relative to it.
  defp files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end
end
