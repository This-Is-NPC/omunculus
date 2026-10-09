defmodule Omunculus.Tools.OverviewTest do
  use ExUnit.Case, async: true

  alias Omunculus.Config.Toml, as: ConfigToml
  alias Omunculus.Fixtures
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Overview

  setup do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    path = Fixtures.config_path(dir)
    outside = Fixtures.tmp_dir()

    data =
      path
      |> Toml.decode_file!()
      |> put_in(["policy", "workspace"], "site")
      |> put_in(["policy", "depth"], %{"1" => %{"workflow" => "delivery"}})
      |> put_in(["workflows", "spare"], %{"steps" => [%{"name" => "only", "agent" => "worker"}]})
      |> Map.put("auth", %{
        "store" => "auth.json",
        "gh" => %{"kind" => "api_key", "key" => "!omapass get -- dev/github"}
      })
      |> put_in(["models", "remote"], %{
        "api" => "openai-completions",
        "url" => "http://127.0.0.1:1/v1",
        "model" => "remote-model",
        "timeout_ms" => 1000,
        "provider" => "gh",
        "body" => %{"reasoning" => %{"effort" => "high"}}
      })
      |> Map.put("secrets", %{"notify" => %{"NOTIFY_TOKEN" => "gh"}})
      |> Map.put("workspaces", %{
        "site" => %{"root" => "site"},
        "notes" => %{
          "root" => outside,
          "human" => ["fs.write"],
          "agents" => %{"worker" => %{"model" => "remote"}}
        }
      })

    File.write!(path, ConfigToml.encode(data))

    skill = Path.join([dir, ".agents", "skills", "review"])
    File.mkdir_p!(skill)

    File.write!(
      Path.join(skill, "SKILL.md"),
      "---\nname: review\ndescription: Reviews code.\nallowed-tools: Read fs.write\n---\n"
    )

    %{path: path}
  end

  defp overview(path) do
    assert %{"ok" => true, "output" => output} = Overview.run(%{config_path: path})
    Jason.decode!(output)
  end

  defp place(overview, name), do: Enum.find(overview["places"], &(&1["workspace"] == name))
  defp depth(place, depth), do: Enum.find(place["depths"], &(&1["depth"] == depth))
  defp tool(agent, name), do: Enum.find(agent["tools"], &(&1["name"] == name))

  test "each workspace is a place; the root is not one while a workspace is the default", %{
    path: path
  } do
    overview = overview(path)
    assert Enum.map(overview["places"], & &1["workspace"]) == ["notes", "site"]
    assert %{"default" => true, "outside" => false} = place(overview, "site")

    assert %{"default" => false, "outside" => true, "changes" => ["agents"]} =
             notes = place(overview, "notes")

    assert notes["layer"]["human"] == ["fs.write"]
    assert overview["unused_workflows"] == ["spare"]
  end

  test "a depth shows its workflow's stages, each with its deny and its agent", %{path: path} do
    site = path |> overview() |> place("site") |> depth(1)
    assert %{"workflow" => "delivery", "changed" => false} = site
    assert [to_do, review] = site["stages"]
    assert %{"name" => "to_do", "agent" => %{"name" => "worker"}} = to_do
    assert %{"name" => "review", "deny" => deny, "agent" => %{"name" => "reviewer"}} = review
    assert "fs.write" in deny
    assert tool(to_do["agent"], "fs.write")["state"] == "have"
    assert tool(to_do["agent"], "fs.write")["members"] == ["edit", "write"]
    assert tool(to_do["agent"], "sandbox.write")["state"] == "sealed"
  end

  test "an agent shows its model, its key's source and its tools as the place has them", %{
    path: path
  } do
    worker = path |> overview() |> place("notes") |> depth(1) |> Map.fetch!("stages") |> hd()
    agent = worker["agent"]

    assert %{
             "name" => "remote",
             "id" => "remote-model",
             "changed" => true,
             "body" => %{"reasoning" => %{"effort" => "high"}}
           } = agent["model"]

    assert agent["key"] == %{"provider" => "gh", "source" => "omapass · dev/github"}
    assert tool(agent, "fs.write")["state"] == "sealed"
    assert tool(agent, "notify")["secrets"] == %{"NOTIFY_TOKEN" => "gh"}
  end

  test "an agent's skills come apart from its tools, each with the tools it uses", %{path: path} do
    worker = path |> overview() |> place("site") |> depth(1) |> Map.fetch!("stages") |> hd()
    agent = worker["agent"]

    assert agent["skills"] == [
             %{
               "name" => "review",
               "description" => "Reviews code.",
               "uses" => ["read", "fs.write"],
               "state" => "have"
             }
           ]

    names = Enum.map(agent["tools"], & &1["name"])
    assert "skill" in names
    refute "skills" in names
  end

  test "the builtin catalog discovers overview with triggers == [\"cli\"]" do
    assert %{"overview" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["cli"]
  end
end
