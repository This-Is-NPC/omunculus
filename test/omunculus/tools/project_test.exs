defmodule Omunculus.Tools.ProjectTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Config, Fixtures}
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.{Project, Work}

  setup do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    path = Fixtures.config_path(dir)
    main = Path.join(dir, "main")
    File.mkdir_p!(main)

    data =
      path
      |> Toml.decode_file!()
      |> Map.put("project", %{"workspaces_dir" => "workspaces"})
      |> Map.put("workspaces", %{
        "main" => %{"root" => main, "client" => "Ada", "summary" => "A bakery site"}
      })
      |> put_in(["policy", "workspace"], "main")

    File.write!(path, Omunculus.Config.Toml.encode(data))
    %{dir: dir, path: path, main: main}
  end

  defp call(path, args), do: Project.run(%{config_path: path, args: args})

  test "is a model tool with no group" do
    assert %{"project" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["model"]
    assert manifest.groups == []
  end

  test "list tells each workspace by its path, client and summary", ctx do
    assert %{"ok" => true, "output" => output} = call(ctx.path, %{"action" => "list"})

    assert Jason.decode!(output) == [
             %{
               "name" => "main",
               "path" => ctx.main,
               "client" => "Ada",
               "summary" => "A bakery site"
             }
           ]
  end

  test "create makes the folder, a git repository and the workspace table", ctx do
    before = Toml.decode_file!(ctx.path)

    assert %{"ok" => true, "output" => output} =
             call(ctx.path, %{
               "action" => "create",
               "name" => "bruno",
               "client" => "Bruno",
               "summary" => "A barbershop site"
             })

    dir = Path.join([ctx.dir, "workspaces", "bruno"])
    assert Jason.decode!(output) == %{"name" => "bruno", "path" => dir}
    assert File.dir?(Path.join(dir, ".git"))

    written = Toml.decode_file!(ctx.path)

    assert written["workspaces"]["bruno"] == %{
             "root" => dir,
             "client" => "Bruno",
             "summary" => "A barbershop site"
           }

    assert put_in(written, ["workspaces"], before["workspaces"]) == before

    # The next run reads the config again, and the workspace is there.
    assert {:ok, %Config{workspaces: %{"bruno" => %{root: ^dir, client: "Bruno"}}}} =
             Config.load(ctx.path)

    assert %{"output" => listed} = call(ctx.path, %{"action" => "list"})
    assert Enum.map(Jason.decode!(listed), & &1["name"]) == ["bruno", "main"]
  end

  test "a created workspace is the one a work names, so the client's later messages go to it",
       ctx do
    assert %{"ok" => true} = call(ctx.path, %{"action" => "create", "name" => "bruno"})

    assert %{"ok" => true, "emit" => [%{"type" => "work", "body" => body}]} =
             Work.run(%{
               args: %{
                 "report" => "opened",
                 "works" => [%{"title" => "Bruno", "goal" => "a site", "workspace" => "bruno"}]
               },
               work_id: nil
             })

    assert [%{"workspace" => "bruno"}] = body["works"]
    assert {:ok, config} = Config.load(ctx.path)
    assert Map.has_key?(config.workspaces, "bruno")
  end

  test "create refuses an existing workspace, an existing folder and a bad name", ctx do
    unchanged = File.read!(ctx.path)

    assert %{"ok" => false, "output" => used} =
             call(ctx.path, %{"action" => "create", "name" => "main"})

    assert used =~ "exists"

    File.mkdir_p!(Path.join([ctx.dir, "workspaces", "taken"]))

    assert %{"ok" => false, "output" => taken} =
             call(ctx.path, %{"action" => "create", "name" => "taken"})

    assert taken =~ "exists"

    assert %{"ok" => false} = call(ctx.path, %{"action" => "create", "name" => "../out"})
    assert %{"ok" => false} = call(ctx.path, %{"action" => "create"})
    assert File.read!(ctx.path) == unchanged
    refute File.exists?(Path.join(ctx.dir, "out"))
  end

  test "create is refused without the root the config names", ctx do
    data = ctx.path |> Toml.decode_file!() |> Map.delete("project")
    File.write!(ctx.path, Omunculus.Config.Toml.encode(data))

    assert %{"ok" => false, "output" => message} =
             call(ctx.path, %{"action" => "create", "name" => "bruno"})

    assert message =~ "workspaces_dir"
    refute File.exists?(Path.join(ctx.dir, "workspaces"))
  end

  test "an unknown action is refused", ctx do
    assert %{"ok" => false} = call(ctx.path, %{"action" => "drop"})
  end
end
