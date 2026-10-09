defmodule Omunculus.Skills do
  @moduledoc """
  Discovers Agent Skills (the agentskills.io format) under the config's
  `[skills] paths`: each folder there holding a `SKILL.md` whose YAML
  frontmatter has a `name` — lowercase letters, digits and single hyphens,
  at most 64, equal to the folder's name — and a `description` of 1 to
  1024 characters. A skill becomes the catalog entry `skill.<name>`, of
  kind `skill`, in the group `skills`, so the ceiling governs it like a
  tool. A folder that breaks those rules is skipped and logged. Paths are
  walked in order; the last skill of a name wins.
  """

  require Logger

  alias Omunculus.Tool.Manifest

  @group "skills"

  @spec discover([String.t()]) :: %{String.t() => Manifest.t()}
  def discover(paths) do
    for root <- paths, File.dir?(root), folder <- folders(root), reduce: %{} do
      skills ->
        case load(folder) do
          {:ok, skill} ->
            Map.put(skills, skill.name, skill)

          {:error, reason} ->
            Logger.warning("skipping skill #{folder}: #{inspect(reason)}")
            skills
        end
    end
  end

  @doc "The catalog name of the skill `name`."
  @spec catalog_name(String.t()) :: String.t()
  def catalog_name(name), do: "skill." <> name

  @doc "The skill's own name, from its catalog name."
  @spec short_name(String.t()) :: String.t()
  def short_name("skill." <> name), do: name

  @spec load(String.t()) :: {:ok, Manifest.t()} | {:error, term}
  def load(folder) do
    with {:ok, text} <- File.read(Path.join(folder, "SKILL.md")),
         {:ok, front} <- frontmatter(text),
         {:ok, name} <- name(front, Path.basename(folder)),
         {:ok, description} <- description(front) do
      {:ok,
       %Manifest{
         name: catalog_name(name),
         kind: "skill",
         triggers: [],
         description: description,
         tags: ["skill"],
         groups: [@group],
         dir: folder
       }}
    end
  end

  defp folders(root) do
    root
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(&Path.join(root, &1))
    |> Enum.filter(&File.regular?(Path.join(&1, "SKILL.md")))
  end

  defp frontmatter("---\n" <> rest) do
    with [yaml, _body] <- String.split(rest, ~r/^---\s*$/m, parts: 2),
         {:ok, front} when is_map(front) <- YamlElixir.read_from_string(yaml) do
      {:ok, front}
    else
      _invalid -> {:error, :frontmatter}
    end
  end

  defp frontmatter(_text), do: {:error, :frontmatter}

  defp name(%{"name" => name}, folder) when is_binary(name) do
    cond do
      name != folder -> {:error, {:name, :folder, name, folder}}
      String.length(name) > 64 -> {:error, {:name, :too_long}}
      name =~ ~r/^[a-z0-9]+(-[a-z0-9]+)*$/ -> {:ok, name}
      true -> {:error, {:name, :invalid, name}}
    end
  end

  defp name(_front, _folder), do: {:error, {:name, :missing}}

  defp description(%{"description" => description}) when is_binary(description) do
    length = description |> String.trim() |> String.length()
    if length in 1..1024, do: {:ok, String.trim(description)}, else: {:error, :description}
  end

  defp description(_front), do: {:error, :description}
end
