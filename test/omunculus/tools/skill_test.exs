defmodule Omunculus.Tools.SkillTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures}
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Skill

  setup do
    root = Fixtures.tmp_dir()
    dir = Path.join(root, "review")
    File.mkdir_p!(Path.join(dir, "references"))

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\nname: review\ndescription: Reviews code.\n---\n\nRead the diff.\n"
    )

    File.write!(Path.join([dir, "references", "checklist.md"]), "- tests pass\n")
    File.write!(Path.join(root, "secret.txt"), "outside")
    File.ln_s!(Path.join(root, "secret.txt"), Path.join(dir, "link.md"))
    %{dir: dir, root: root}
  end

  defp call(dir, args) do
    view = %{"skills" => [%{name: "review", description: "Reviews code.", dir: dir}]}
    Skill.run(%{name: "skill", args: args, view: view})
  end

  test "gives the skill's instructions and the files of its folder", %{dir: dir} do
    assert %{"ok" => true, "output" => output} = call(dir, %{"name" => "review"})
    assert output =~ "Read the diff."
    assert output =~ "## Files\n- link.md\n- references/checklist.md"
  end

  test "gives one file of its folder, and none outside it", %{dir: dir} do
    assert %{"ok" => true, "output" => "- tests pass\n"} =
             call(dir, %{"name" => "review", "file" => "references/checklist.md"})

    for outside <- ["../secret.txt", "link.md", "/etc/passwd"] do
      assert %{"ok" => false, "output" => output} =
               call(dir, %{"name" => "review", "file" => outside})

      assert output =~ "outside the skill"
    end

    assert %{"ok" => false, "output" => "review has no file nope.md"} =
             call(dir, %{"name" => "review", "file" => "nope.md"})
  end

  test "refuses a skill the run does not have", %{dir: dir} do
    assert %{"ok" => false, "output" => "no skill other in this run"} =
             call(dir, %{"name" => "other"})
  end

  test "an agent with the skills group sees ## Skills and reads one" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    skill = Path.join([dir, ".agents", "skills", "review"])
    File.mkdir_p!(skill)

    File.write!(
      Path.join(skill, "SKILL.md"),
      "---\nname: review\ndescription: Reviews code.\n---\n\nRead the diff.\n"
    )

    test_pid = self()

    Fixtures.use_model(dir, fn assembled, _tools, call ->
      send(test_pid, {:assembled, assembled})
      send(test_pid, {:read, call.("skill", %{"name" => "review"})})
      {:ok, "reviewed"}
    end)

    assert {:ok, ""} = CLI.run(["send", "review this"], dir)
    assert_received {:assembled, assembled}

    assert assembled =~
             "## Skills\nRead a skill with the skill tool before you follow it.\n- review: Reviews code."

    assert_received {:read, {:ok, text}}
    assert text =~ "Read the diff."
  end

  test "the builtin skill tool is a model tool in the skills group" do
    assert %{"skill" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["skills"]
  end
end
