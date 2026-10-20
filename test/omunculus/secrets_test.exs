defmodule Omunculus.SecretsTest do
  use ExUnit.Case, async: true

  alias Omunculus.{ExecutionPolicyFixtures, Fixtures, Harness, Project, Secrets}
  alias Omunculus.Store.Query
  alias Omunculus.Tool.Manifest

  import Omunculus.Fixtures, only: [open_project: 1, write_tool: 4]

  setup do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    %{dir: dir}
  end

  defp append(dir, toml), do: File.write!(Fixtures.config_path(dir), toml, [:append])

  defp keyed_config(dir, secrets) do
    append(dir, """

    [auth]
    store = "auth.json"

    [auth.gh]
    kind = "api_key"
    key = "!printf token-value"

    #{secrets}
    """)
  end

  # A cli tool that answers with what it read from its secret's file.
  defp leak_tool(dir, declared) do
    write_tool(
      dir,
      "leak",
      """
      name = "leak"
      kind = "tool"
      triggers = ["cli"]
      command = ["./run"]
      secrets = #{declared}
      """,
      """
      #!/bin/sh
      value=$(cat "$GH_TOKEN_FILE")
      printf '{"ok": true, "output": "length %s: %s", "emit": []}' "${#value}" "$value"
      """
    )
  end

  defp dispatch(dir, name) do
    project = open_project(dir)
    execution = ExecutionPolicyFixtures.policy(dir, network: "none")
    ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil, execution: execution}

    try do
      {Harness.dispatch(project, name, %{}, ctx),
       Query.all(project.conn, "SELECT body FROM events")}
    after
      Project.close(project)
    end
  end

  test "a tool's process reads its secret, and what it returns has the value masked", %{
    dir: dir
  } do
    keyed_config(dir, "[secrets.leak]\nGH_TOKEN = \"gh\"")
    leak_tool(dir, ~s(["GH_TOKEN"]))

    assert {{:ok, %{ok: true, output: "length 11: ***"}, _events}, {:ok, rows}} =
             dispatch(dir, "leak")

    refute Enum.any?(rows, &(&1.body =~ "token-value"))
  end

  test "a declared secret left unbound, or a bound one not declared, refuses the call", %{
    dir: dir
  } do
    keyed_config(dir, "")
    leak_tool(dir, ~s(["GH_TOKEN"]))
    assert {{:error, {:secrets, "leak", {:unbound, "GH_TOKEN"}}}, _rows} = dispatch(dir, "leak")

    append(dir, "\n[secrets.leak]\nGH_TOKEN = \"gh\"\nOTHER = \"gh\"\n")
    assert {{:error, {:secrets, "leak", {:undeclared, "OTHER"}}}, _rows} = dispatch(dir, "leak")
  end

  test "a binding to a provider [auth] lacks does not load", %{dir: dir} do
    keyed_config(dir, "[secrets.leak]\nGH_TOKEN = \"missing\"")

    assert {:error, {:secrets, "leak", {:unknown_provider, "missing"}}} =
             Fixtures.load_config(dir)
  end

  test "an MCP server's secrets are bound in its own table" do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)

    keyed_config(dir, """
    [[mcp.servers]]
    name = "github"
    command = ["github-mcp"]
    protocol_version = "2025-03-26"
    secrets = { GITHUB_TOKEN = "gh" }
    """)

    assert {:ok, config} = Fixtures.load_config(dir)
    assert [%{name: "github", secrets: %{"GITHUB_TOKEN" => "gh"}}] = config.mcp
    manifest = %Manifest{name: "search", kind: "tool", dir: nil, mcp: hd(config.mcp)}
    assert {:ok, %{"GITHUB_TOKEN" => "token-value"}} = Secrets.for_tool(config, manifest)
  end

  test "mask hides every value in strings, lists, maps and tuples, the longest first" do
    values = %{"A" => "abc", "B" => "abcdef"}

    assert Secrets.mask({:error, {:exit, 1, "saw abcdef and abc"}}, values) ==
             {:error, {:exit, 1, "saw *** and ***"}}

    assert Secrets.mask(%{output: ["abc"], ok: true}, values) == %{output: ["***"], ok: true}
    assert Secrets.mask("abc", %{}) == "abc"
  end

  test "a manifest's secrets belong to a command tool and are variable names" do
    base = %{"name" => "t", "kind" => "tool", "command" => ["./run"]}

    assert {:ok, %Manifest{secrets: ["GH_TOKEN"]}} =
             Manifest.parse(Map.put(base, "secrets", ["GH_TOKEN"]), "/")

    assert {:error, {:invalid, :secrets}} =
             Manifest.parse(Map.put(base, "secrets", ["GH-TOKEN"]), "/")

    module = %{"name" => "t", "kind" => "tool", "module" => "Omunculus.Tools.Comment"}

    assert {:error, {:invalid, :secrets}} =
             Manifest.parse(Map.put(module, "secrets", ["GH_TOKEN"]), "/")
  end
end
