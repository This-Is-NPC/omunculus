defmodule Omunculus.Tools.ToolsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Config.Toml, as: ConfigToml
  alias Omunculus.Fixtures
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Tools

  test "lists each tool and skill with its source, groups and secrets, and the MCP servers" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    skill = Path.join([dir, ".agents", "skills", "review"])
    File.mkdir_p!(skill)

    File.write!(
      Path.join(skill, "SKILL.md"),
      "---\nname: review\ndescription: Reviews code.\n---\n"
    )

    path = Fixtures.config_path(dir)

    data =
      path
      |> Toml.decode_file!()
      |> put_in(["tools", "echo"], %{"kind" => "tool", "module" => "Omunculus.Tools.Comment"})
      |> Map.put("auth", %{"store" => "auth.json", "gh" => %{"kind" => "api_key", "key" => "$GH"}})
      |> Map.put("secrets", %{"notify" => %{"NOTIFY_TOKEN" => "gh"}})
      |> Map.put("mcp", %{
        "servers" => [
          %{
            "name" => "github",
            "command" => ["github-mcp"],
            "protocol_version" => "2025-03-26",
            "secrets" => %{"GITHUB_TOKEN" => "gh"}
          }
        ]
      })

    File.write!(path, ConfigToml.encode(data))

    assert %{"ok" => true, "output" => output} = Tools.run(%{config_path: path})
    listed = Jason.decode!(output)
    by_name = Map.new(listed["tools"], &{&1["name"], &1})

    assert %{"kind" => "tool", "source" => "folder", "triggers" => ["model"]} = by_name["read"]
    assert %{"source" => "inline"} = by_name["echo"]
    assert %{"binding" => %{"NOTIFY_TOKEN" => "gh"}} = by_name["notify"]

    assert %{"kind" => "skill", "source" => "skill", "groups" => ["skills"], "dir" => ^skill} =
             by_name["skill.review"]

    assert listed["mcp"] == [
             %{
               "name" => "github",
               "command" => ["github-mcp"],
               "secrets" => %{"GITHUB_TOKEN" => "gh"}
             }
           ]
  end

  test "the builtin catalog discovers tools with triggers == [\"cli\"]" do
    assert %{"tools" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["cli"]
  end
end
