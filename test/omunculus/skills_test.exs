defmodule Omunculus.SkillsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Omunculus.{Fixtures, Skills}
  alias Omunculus.Tool.Catalog

  defp skill(root, folder, front, body \\ "Do the thing.\n") do
    dir = Path.join(root, folder)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\n" <> front <> "---\n\n" <> body)
    dir
  end

  test "a SKILL.md folder becomes skill.<name> in the skills group" do
    root = Fixtures.tmp_dir()
    dir = skill(root, "pdf-tools", "name: pdf-tools\ndescription: Reads PDFs. Use for PDFs.\n")

    assert %{"skill.pdf-tools" => skill} = Skills.discover([root])
    assert skill.kind == "skill"
    assert skill.description == "Reads PDFs. Use for PDFs."
    assert skill.groups == ["skills"]
    assert skill.triggers == []
    assert skill.dir == dir
  end

  test "a description may span lines, as YAML folds it" do
    root = Fixtures.tmp_dir()

    skill(root, "notes", """
    name: notes
    description: >
      Takes notes
      in a file.
    metadata:
      author: someone
    """)

    assert %{"skill.notes" => %{description: "Takes notes in a file."}} = Skills.discover([root])
  end

  test "a folder that breaks the format is skipped and logged" do
    root = Fixtures.tmp_dir()
    skill(root, "Upper", "name: Upper\ndescription: x\n")
    skill(root, "other", "name: not-other\ndescription: x\n")
    skill(root, "double--hyphen", "name: double--hyphen\ndescription: x\n")
    skill(root, "silent", "name: silent\n")
    skill(root, "long", "name: long\ndescription: #{String.duplicate("x", 1025)}\n")
    File.mkdir_p!(Path.join(root, "plain"))
    File.write!(Path.join([root, "plain", "SKILL.md"]), "no frontmatter")

    log = capture_log(fn -> assert Skills.discover([root]) == %{} end)
    assert log =~ "skipping skill"
    assert Skills.discover([Path.join(root, "missing")]) == %{}
  end

  test "the last path wins for a name both hold" do
    user = Fixtures.tmp_dir()
    project = Fixtures.tmp_dir()
    skill(user, "review", "name: review\ndescription: the user's\n")
    skill(project, "review", "name: review\ndescription: the project's\n")

    assert %{"skill.review" => %{description: "the project's"}} = Skills.discover([user, project])
  end

  test "the catalog holds the skills of [skills] paths beside the tools" do
    root = Fixtures.tmp_dir()
    skill(root, "review", "name: review\ndescription: Reviews.\n")
    catalog = Catalog.discover(%{paths: [], inline: %{}, skills: [root]})

    assert %{"skill.review" => _skill} = catalog
    assert Catalog.groups(catalog) == %{"skills" => ["skill.review"]}
    assert Catalog.with_trigger(catalog, "model") == %{}
  end

  defp with_skills(dir, table) do
    path = Fixtures.config_path(dir)
    data = path |> Toml.decode_file!() |> Map.put("skills", table)
    File.write!(path, Omunculus.Config.Toml.encode(data))
  end

  test "[skills] paths are relative to the config file, ~ to the home" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    with_skills(dir, %{"paths" => ["~/.agents/skills", ".agents/skills"]})

    assert {:ok, config} = Fixtures.load_config(dir)

    assert config.tools.skills == [
             Path.expand("~/.agents/skills"),
             Path.join(dir, ".agents/skills")
           ]
  end

  test "[skills] takes only paths, a list of non-empty strings" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)

    with_skills(dir, %{"folders" => []})
    assert {:error, {:skills, {:unknown_key, "folders"}}} = Fixtures.load_config(dir)

    with_skills(dir, %{"paths" => [""]})
    assert {:error, {:skills, {:invalid, :paths}}} = Fixtures.load_config(dir)
  end
end
