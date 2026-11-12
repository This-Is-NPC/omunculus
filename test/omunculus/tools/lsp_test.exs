defmodule Omunculus.Tools.LspTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.{Invoke, Manifest}

  @moduletag skip:
               if(System.find_executable("clangd"), do: false, else: "clangd is not installed")

  @source """
  int add(int a, int b) { return a + b; }
  int main(void) { int x = add(1, 2); return missing + x; }
  """

  setup do
    workspace = Omunculus.Fixtures.tmp_dir()
    File.write!(Path.join(workspace, "a.c"), @source)
    {:ok, manifest} = Manifest.load(Path.expand("priv/tools/lsp/tool.toml"))

    policy =
      ExecutionPolicyFixtures.policy(workspace,
        read_only: [workspace, manifest.dir],
        limits: %{timeout_ms: 30_000, max_output_bytes: 65_536}
      )

    %{workspace: workspace, manifest: manifest, policy: policy}
  end

  defp lsp(%{workspace: workspace, manifest: manifest, policy: policy}, args, view \\ nil) do
    view = view || %{"lsp" => %{"c" => %{"command" => ["clangd"], "extensions" => ["c"]}}}

    input = %{
      name: "lsp",
      args: args,
      view: view,
      run_id: "run-#{System.unique_integer([:positive])}",
      work_id: nil,
      workspace: ".",
      roots: [workspace]
    }

    assert {:ok, out} = Invoke.call(manifest, input, policy)
    out
  end

  test "diagnostics, definition, references and symbols of a file", context do
    assert %{ok: true, output: diagnostics} =
             lsp(context, %{"action" => "diagnostics", "path" => "a.c"})

    assert diagnostics =~ "a.c:2:44 error"
    assert diagnostics =~ "missing"

    assert %{ok: true, output: definition} =
             lsp(context, %{
               "action" => "definition",
               "path" => "a.c",
               "line" => 2,
               "column" => 28
             })

    assert definition =~ "a.c:1:5  int add(int a, int b)"

    assert %{ok: true, output: references} =
             lsp(context, %{"action" => "references", "path" => "a.c", "line" => 1, "column" => 5})

    assert references =~ "a.c:1:5"
    assert references =~ "a.c:2:26"

    assert %{ok: true, output: "function add 1:5\nfunction main 2:5"} =
             lsp(context, %{"action" => "symbols", "path" => "a.c"})

    assert %{ok: true, output: hover} =
             lsp(context, %{"action" => "hover", "path" => "a.c", "line" => 1, "column" => 5})

    assert hover =~ "add"
  end

  test "a file with no language server declared is refused in words", context do
    File.write!(Path.join(context.workspace, "a.py"), "")

    assert %{ok: false, output: "no language server is declared for .py; declared: c"} =
             lsp(context, %{"action" => "symbols", "path" => "a.py"})

    assert %{ok: false, output: "no language server is declared: " <> _} =
             lsp(context, %{"action" => "symbols", "path" => "a.c"}, %{})
  end

  test "a position action without a position is refused", context do
    assert %{ok: false, output: "hover needs line and column"} =
             lsp(context, %{"action" => "hover", "path" => "a.c"})
  end
end
