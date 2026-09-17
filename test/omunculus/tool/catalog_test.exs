defmodule Omunculus.Tool.CatalogTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tool.Manifest

  setup do
    project_dir = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(project_dir)
    on_exit(fn -> File.rm_rf!(project_dir) end)
    %{project_dir: project_dir}
  end

  defp tools(paths, inline \\ %{}) do
    %{paths: List.wrap(paths), inline: inline}
  end

  defp write_tool(root, name, filename \\ "tool.toml", content) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), content)
    dir
  end

  defp mcp_policy do
    implementation_root = Path.expand("test/support")

    ExecutionPolicyFixtures.policy(implementation_root,
      read_only: [implementation_root],
      network: "host"
    )
  end

  test "discovers a tool folder", %{project_dir: project_dir} do
    write_tool(project_dir, "read", """
    name = "read"
    kind = "tool"
    command = ["./run"]
    """)

    catalog = Catalog.discover(tools(project_dir))
    assert %{"read" => manifest} = catalog
    assert manifest.dir == Path.join(project_dir, "read")
  end

  test "a later path overrides an earlier one on the same name", %{project_dir: project_dir} do
    first = Path.join(project_dir, "first")
    second = Path.join(project_dir, "second")

    write_tool(first, "send", """
    name = "send"
    kind = "tool"
    description = "first"
    command = ["./run"]
    """)

    write_tool(second, "send", """
    name = "send"
    kind = "tool"
    description = "second"
    command = ["./run"]
    """)

    catalog = Catalog.discover(tools([first, second]))
    assert catalog["send"].description == "second"
  end

  test "a folder without a manifest is ignored", %{project_dir: project_dir} do
    File.mkdir_p!(Path.join(project_dir, "empty"))

    write_tool(project_dir, "read", """
    name = "read"
    kind = "tool"
    command = ["./run"]
    """)

    catalog = Catalog.discover(tools(project_dir))
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

    catalog = Catalog.discover(tools(project_dir))
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

    catalog = Catalog.discover(tools(project_dir))
    assert catalog == %{}
  end

  test "a hook.toml folder is discovered too", %{project_dir: project_dir} do
    write_tool(project_dir, "on-request", "hook.toml", """
    name = "on-request"
    kind = "hook"
    events = ["request"]
    command = ["./run"]
    """)

    catalog = Catalog.discover(tools(project_dir))
    assert %{"on-request" => manifest} = catalog
    assert manifest.kind == "hook"
  end

  test "a nonexistent path is skipped" do
    assert Catalog.discover(tools(Path.join(System.tmp_dir!(), Omunculus.Id.new()))) == %{}
  end

  test "an empty tools table yields an empty catalog" do
    assert Catalog.discover(tools([])) == %{}
  end

  test "a path that is not listed is not discovered", %{project_dir: project_dir} do
    hidden = Path.join(project_dir, "hidden")

    write_tool(hidden, "secret", """
    name = "secret"
    kind = "tool"
    command = ["./run"]
    """)

    assert Catalog.discover(tools([])) == %{}
    refute Map.has_key?(Catalog.unconfigured(), "secret")
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

    catalog = Catalog.discover(tools(project_dir))
    assert Map.keys(Catalog.with_trigger(catalog, "model")) == ["read"]
    assert Map.keys(Catalog.with_trigger(catalog, "cli")) == ["send"]
  end

  test "package tools discover send with triggers == [\"cli\"]" do
    catalog = Catalog.unconfigured()

    assert %{"send" => manifest} = catalog
    assert manifest.triggers == ["cli"]
  end

  test "hooks_for/2 returns the hooks whose events include the type, sorted by name" do
    catalog = Catalog.unconfigured()

    assert Enum.map(Catalog.hooks_for(catalog, "request"), & &1.name) == ["on-request"]
    assert Catalog.hooks_for(catalog, "prompt") == []
  end

  test "a hook never appears in with_trigger/2, neither for \"model\" nor \"cli\"" do
    catalog = Catalog.unconfigured()

    refute Map.has_key?(Catalog.with_trigger(catalog, "model"), "on-request")
    refute Map.has_key?(Catalog.with_trigger(catalog, "cli"), "on-request")
  end

  test "groups/1 maps a group name to the sorted names of the manifests that list it", %{
    project_dir: project_dir
  } do
    write_tool(project_dir, "read", """
    name = "read"
    kind = "tool"
    groups = ["fs.read"]
    command = ["./run"]
    """)

    write_tool(project_dir, "ls", """
    name = "ls"
    kind = "tool"
    groups = ["fs.read"]
    command = ["./run"]
    """)

    write_tool(project_dir, "write", """
    name = "write"
    kind = "tool"
    groups = ["fs.write"]
    command = ["./run"]
    """)

    catalog = Catalog.discover(tools(project_dir))

    assert Catalog.groups(catalog) == %{
             "fs.read" => ["ls", "read"],
             "fs.write" => ["write"]
           }
  end

  test "groups/1 ignores a manifest without groups", %{project_dir: project_dir} do
    write_tool(project_dir, "counter", """
    name = "counter"
    kind = "tool"
    command = ["./run"]
    """)

    catalog = Catalog.discover(tools(project_dir))
    assert Catalog.groups(catalog) == %{}
  end

  test "builtin fs.read is find, grep, ls and read" do
    catalog = Catalog.unconfigured()

    assert Catalog.groups(catalog)["fs.read"] == ["find", "grep", "ls", "read"]
    assert catalog["directory"].groups == []
    assert catalog["workspaces"].groups == []
  end

  test "inline tables win over a path of the same name", %{project_dir: project_dir} do
    write_tool(project_dir, "echo", """
    name = "echo"
    kind = "tool"
    description = "from the folder"
    command = ["./run"]
    """)

    {:ok, inline} =
      Manifest.parse(
        %{
          "name" => "echo",
          "kind" => "tool",
          "description" => "from inline",
          "module" => "Omunculus.Tools.Comment"
        },
        project_dir
      )

    catalog = Catalog.discover(tools(project_dir, %{"echo" => inline}))
    assert catalog["echo"].description == "from inline"
  end

  describe "MCP servers" do
    @mcp_server %{
      name: "fake",
      command: [Path.expand("test/support/mcp_server")],
      protocol_version: "2025-03-26"
    }

    test "a server's tools/list becomes names in the catalog, tagged and carrying the server", %{
      project_dir: project_dir
    } do
      catalog = Catalog.discover(tools(project_dir), [@mcp_server], mcp_policy())

      assert %{"echo" => echo, "shout" => shout} = catalog
      assert echo.description == "Echoes text"
      assert echo.tags == ["mcp", "fake"]
      assert echo.mcp == @mcp_server
      assert echo.dir == nil
      assert shout.description == "Upper-cases text"
    end

    test "an MCP tool wins over a path tool of the same name", %{project_dir: project_dir} do
      write_tool(project_dir, "echo", """
      name = "echo"
      kind = "tool"
      description = "from the folder"
      command = ["./run"]
      """)

      catalog = Catalog.discover(tools(project_dir), [@mcp_server], mcp_policy())
      assert catalog["echo"].mcp == @mcp_server
      assert catalog["echo"].description == "Echoes text"
    end

    test "an inline tool wins over an MCP tool of the same name", %{project_dir: project_dir} do
      {:ok, inline} =
        Manifest.parse(
          %{
            "name" => "echo",
            "kind" => "tool",
            "description" => "from inline",
            "module" => "Omunculus.Tools.Comment"
          },
          project_dir
        )

      catalog = Catalog.discover(tools([], %{"echo" => inline}), [@mcp_server], mcp_policy())
      assert catalog["echo"].description == "from inline"
      assert catalog["echo"].mcp == nil
    end

    test "a server that fails to list is skipped, not raised", %{project_dir: project_dir} do
      broken = %{
        name: "broken",
        command: ["definitely-not-a-real-binary-xyz"],
        protocol_version: "2025-03-26"
      }

      write_tool(project_dir, "read", """
      name = "read"
      kind = "tool"
      command = ["./run"]
      """)

      catalog = Catalog.discover(tools(project_dir), [broken], mcp_policy())
      assert Map.keys(catalog) == ["read"]
    end
  end
end
