defmodule Omunculus.Tool.CatalogTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.Catalog

  setup do
    project_dir = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(project_dir)
    on_exit(fn -> File.rm_rf!(project_dir) end)
    %{project_dir: project_dir}
  end

  defp write_tool(root, name, filename \\ "tool.toml", content) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), content)
    dir
  end

  test "roots/1 orders builtin, user, then project, least to most specific", %{
    project_dir: project_dir
  } do
    assert Catalog.roots(project_dir) == [
             Application.app_dir(:omunculus, "priv/tools"),
             Path.expand("~/.omunculus/tools"),
             Path.join(project_dir, "tools")
           ]
  end

  test "discovers a tool folder", %{project_dir: project_dir} do
    write_tool(project_dir, "read", """
    name = "read"
    kind = "tool"
    command = ["./run"]
    """)

    catalog = Catalog.discover([project_dir])
    assert %{"read" => manifest} = catalog
    assert manifest.dir == Path.join(project_dir, "read")
  end

  test "a later root overrides an earlier one on the same name", %{project_dir: project_dir} do
    builtin = Path.join(project_dir, "builtin")
    project = Path.join(project_dir, "project")

    write_tool(builtin, "send", """
    name = "send"
    kind = "tool"
    description = "builtin"
    command = ["./run"]
    """)

    write_tool(project, "send", """
    name = "send"
    kind = "tool"
    description = "do projeto"
    command = ["./run"]
    """)

    catalog = Catalog.discover([builtin, project])
    assert catalog["send"].description == "do projeto"
  end

  test "a folder without a manifest is ignored", %{project_dir: project_dir} do
    File.mkdir_p!(Path.join(project_dir, "empty"))

    write_tool(project_dir, "read", """
    name = "read"
    kind = "tool"
    command = ["./run"]
    """)

    catalog = Catalog.discover([project_dir])
    assert Map.keys(catalog) == ["read"]
  end

  test "a broken manifest is skipped, not raised", %{project_dir: project_dir} do
    write_tool(project_dir, "broken", """
    kind = "tool"
    command = ["./run"]
    """)

    write_tool(project_dir, "read", """
    name = "read"
    kind = "tool"
    command = ["./run"]
    """)

    catalog = Catalog.discover([project_dir])
    assert Map.keys(catalog) == ["read"]
  end

  test "a folder with both tool.toml and hook.toml is skipped as ambiguous", %{
    project_dir: project_dir
  } do
    dir = Path.join(project_dir, "ambiguous")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "tool.toml"), """
    name = "ambiguous"
    kind = "tool"
    command = ["./run"]
    """)

    File.write!(Path.join(dir, "hook.toml"), """
    name = "ambiguous"
    kind = "hook"
    events = ["request"]
    command = ["./run"]
    """)

    catalog = Catalog.discover([project_dir])
    assert catalog == %{}
  end

  test "a hook.toml folder is discovered too", %{project_dir: project_dir} do
    write_tool(project_dir, "on-request", "hook.toml", """
    name = "on-request"
    kind = "hook"
    events = ["request"]
    command = ["./run"]
    """)

    catalog = Catalog.discover([project_dir])
    assert %{"on-request" => manifest} = catalog
    assert manifest.kind == "hook"
  end

  test "a nonexistent root is skipped" do
    assert Catalog.discover([Path.join(System.tmp_dir!(), Omunculus.Id.new())]) == %{}
  end

  test "with_trigger/2 filters by trigger", %{project_dir: project_dir} do
    write_tool(project_dir, "read", """
    name = "read"
    kind = "tool"
    triggers = ["model"]
    command = ["./run"]
    """)

    write_tool(project_dir, "send", """
    name = "send"
    kind = "tool"
    triggers = ["cli"]
    command = ["./run"]
    """)

    catalog = Catalog.discover([project_dir])
    assert Map.keys(Catalog.with_trigger(catalog, "model")) == ["read"]
    assert Map.keys(Catalog.with_trigger(catalog, "cli")) == ["send"]
  end

  test "roots/1's builtin root discovers send with triggers == [\"cli\"]" do
    [builtin_root | _] = Catalog.roots(".")
    catalog = Catalog.discover([builtin_root])

    assert %{"send" => manifest} = catalog
    assert manifest.triggers == ["cli"]
  end
end
