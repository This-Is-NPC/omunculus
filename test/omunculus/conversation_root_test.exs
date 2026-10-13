defmodule Omunculus.ConversationRootTest do
  use ExUnit.Case, async: false

  alias Omunculus.{CLI, Fixtures}

  import Omunculus.Fixtures, only: [write_config: 2]

  @toml """
  [project]
  conversations = "clients"

  [agents.concierge]
  depth = 0
  text = "concierge"
  tools = ["read", "write", "end", "sandbox.write"]

  [access]
  creator_role = "participant"
  bootstrap_role = "admin"

  [access.roles.admin]
  scope = "project"
  capabilities = ["project.manage_access", "project.manage_config", "conversation.create", "conversation.read", "conversation.send"]

  [access.roles.participant]
  scope = "conversation"
  capabilities = ["conversation.read", "conversation.send", "conversation.manage_access"]
  """

  setup do
    dir = Fixtures.tmp_dir()
    write_config(dir, @toml)
    File.mkdir_p!(Path.join(dir, "templates"))
    File.write!(Path.join([dir, "templates", "proposal.md"]), "template")
    %{dir: dir}
  end

  defp folders(dir) do
    dir |> Path.join("clients") |> File.ls!() |> Enum.reject(&String.starts_with?(&1, "."))
  end

  test "each conversation works in a folder of its own, copied from the workspace", %{dir: dir} do
    model = fn assembled, _tools, call ->
      said = if assembled =~ "first", do: "first", else: "second"
      assert {:ok, "template"} = call.("read", %{"path" => "templates/proposal.md"})
      assert {:ok, missing} = call.("read", %{"path" => "quote.md"})
      refute missing =~ "prices"
      assert {:ok, ""} = call.("write", %{"path" => "quote.md", "content" => "prices #{said}"})
      {:ok, "done"}
    end

    Fixtures.use_model(dir, model)
    local = Omunculus.Operations.local_principal()

    assert {:ok, _bootstrapped} =
             CLI.run(
               ["access", "bootstrap", "--issuer", "local", "--subject", local.subject],
               dir
             )

    assert {:ok, ""} = CLI.run(["send", "first"], dir)
    assert {:ok, ""} = CLI.run(["send", "second"], dir)

    assert [one, two] = folders(dir)
    quotes = Enum.map([one, two], &File.read!(Path.join([dir, "clients", &1, "quote.md"])))
    assert Enum.sort(quotes) == ["prices first", "prices second"]
    refute File.exists?(Path.join(dir, "quote.md"))

    # What omunculus keeps in the workspace stays out of the copies.
    for folder <- [one, two] do
      root = Path.join([dir, "clients", folder])
      assert File.read!(Path.join([root, "templates", "proposal.md"])) == "template"
      refute File.exists?(Path.join(root, ".omunculus"))
      refute File.exists?(Path.join(root, "omunculus.toml"))
      refute File.exists?(Path.join(root, "clients"))
    end
  end

  test "a folder outside the workspace, or the workspace itself, is refused", %{dir: dir} do
    for value <- ["../clients", "/tmp/clients", ".", ""] do
      write_config(dir, String.replace(@toml, ~s("clients"), inspect(value)))

      assert {:error, {:project, {:invalid, :conversations}}} = Fixtures.load_config(dir)
    end
  end
end
