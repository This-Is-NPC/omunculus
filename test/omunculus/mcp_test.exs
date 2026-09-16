defmodule Omunculus.McpTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Config, Fixtures, Id, Mcp, Project}
  alias Omunculus.Tool.Catalog

  @server %{name: "fake", command: [Path.expand("test/support/mcp_server")]}

  defp server(overrides), do: Map.merge(@server, overrides)

  describe "list_tools/1" do
    test "returns the fixture's two tools with description and parameters" do
      assert {:ok, tools} = Mcp.list_tools(@server)
      assert Enum.map(tools, & &1.name) |> Enum.sort() == ["echo", "shout"]

      echo = Enum.find(tools, &(&1.name == "echo"))
      assert echo.description == "Echoes text"
      assert echo.parameters["type"] == "object"
    end

    test "an executable that does not exist is :not_found" do
      assert Mcp.list_tools(server(%{command: ["definitely-not-a-real-binary-xyz"]})) ==
               {:error, {:mcp, "fake", :not_found}}
    end

    test "a server that exits before answering reports its exit status" do
      assert Mcp.list_tools(server(%{command: ["sh", "-c", "exit 3"]})) ==
               {:error, {:mcp, "fake", {:exit, 3}}}
    end
  end

  describe "call/3" do
    test "echo returns the given text" do
      assert {:ok, %{ok: true, output: "hi", emit: []}} =
               Mcp.call(@server, "echo", %{"text" => "hi"})
    end

    test "shout upper-cases the given text" do
      assert {:ok, %{ok: true, output: "HI", emit: []}} =
               Mcp.call(@server, "shout", %{"text" => "hi"})
    end

    test "an unknown tool answers ok: false" do
      assert {:ok, %{ok: false, output: "unknown tool"}} = Mcp.call(@server, "nope", %{})
    end

    test "an executable that does not exist is :not_found" do
      assert Mcp.call(server(%{command: ["definitely-not-a-real-binary-xyz"]}), "echo", %{}) ==
               {:error, {:mcp, "fake", :not_found}}
    end
  end

  describe "end-to-end through Omunculus.CLI.run/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), Id.new())
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    defp write_config(dir, contents), do: Fixtures.write_config(dir, contents)

    defp open(dir) do
      {:ok, project} = Project.open(dir)
      project
    end

    defp mcp_config(command_path) do
      """
      [agents.concierge]
      depth = 0
      text = "hi"
      tools = ["echo", "whisper"]
      deny = ["shout"]

      [[mcp.servers]]
      name = "fake"
      command = ["#{command_path}"]
      """
    end

    test "the model sees echo's card, calls it, is denied shout, and denied an unexposed grant",
         %{dir: dir} do
      write_config(dir, mcp_config(@server.command |> hd()))
      test_pid = self()

      model = fn assembled, _tools, call ->
        send(test_pid, {:assembled, assembled})
        assert {:ok, "oi"} = call.("echo", %{"text" => "oi"})
        assert {:error, {:not_allowed, "shout"}} = call.("shout", %{"text" => "oi"})
        assert {:error, {:not_allowed, "whisper"}} = call.("whisper", %{})
        {:ok, "done"}
      end

      assert {:ok, ""} = CLI.run(["send", "oi"], dir, model)

      assert_received {:assembled, assembled}
      assert assembled =~ "- echo:"
      refute assembled =~ "- shout:"
      refute assembled =~ "- whisper:"
      refute assembled =~ "- mcp:"

      project = open(dir)
      assert {:ok, events} = Omunculus.Store.replay(project.conn, :project)

      tool_names =
        events |> Enum.filter(&(&1.type == "tool")) |> Enum.map(&Jason.decode!(&1.body)["name"])

      assert "echo" in tool_names
      refute "shout" in tool_names
      Project.close(project)
    end

    test "no tool named mcp exists in the catalog even with a server configured", %{dir: dir} do
      write_config(dir, mcp_config(@server.command |> hd()))

      {:ok, config} = Config.load(dir)
      catalog = Catalog.discover(Catalog.roots(dir), config.mcp)

      refute Map.has_key?(catalog, "mcp")
      assert Map.has_key?(catalog, "echo")
    end
  end
end
