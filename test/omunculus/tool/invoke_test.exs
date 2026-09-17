defmodule Omunculus.Tool.InvokeTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.{Catalog, Invoke, Manifest}

  @input %{
    name: "whatever",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: ".",
    roots: []
  }

  setup do
    dir = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp manifest(dir, overrides \\ %{}) do
    struct!(
      %Manifest{
        name: "fixture",
        kind: "tool",
        command: ["./run"],
        dir: dir
      },
      overrides
    )
  end

  defp write_run!(dir, content) do
    path = Path.join(dir, "run")
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  test "happy path returns ok, output and emit", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    cat <<'JSON'
    {"ok": true, "output": "done", "emit": [{"type": "prompt", "body": {"message": "hi"}}]}
    JSON
    """)

    assert {:ok, result} = Invoke.call(manifest(dir), @input, policy(dir))

    assert result == %{
             ok: true,
             output: "done",
             emit: [%{"type" => "prompt", "body" => %{"message" => "hi"}}]
           }
  end

  test "input reaches stdin", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    message=$(cat | sed -n 's/.*"message":"\\([^"]*\\)".*/\\1/p')
    printf '{"ok": true, "output": "", "emit": [{"type": "echo", "body": {"message": "%s"}}]}' "$message"
    """)

    input = %{@input | args: %{"message" => "count to 5"}}
    assert {:ok, result} = Invoke.call(manifest(dir), input, policy(dir))
    assert result.emit == [%{"type" => "echo", "body" => %{"message" => "count to 5"}}]
  end

  test "emit defaults to [] and output defaults to \"\"", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    echo '{"ok": true}'
    """)

    assert {:ok, %{ok: true, output: "", emit: []}} =
             Invoke.call(manifest(dir), @input, policy(dir))
  end

  test "non-zero exit returns the exit error", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    echo 'boom' >&2
    exit 3
    """)

    assert {:error, {:exit, 3, "boom\n"}} = Invoke.call(manifest(dir), @input, policy(dir))
  end

  test "non-JSON stdout is rejected", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    echo 'not json'
    """)

    assert {:error, {:invalid_output, "not json\n"}} =
             Invoke.call(manifest(dir), @input, policy(dir))
  end

  test "bad shape: emit entry without body is rejected", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    echo '{"ok": true, "output": "", "emit": [{"type": "prompt"}]}'
    """)

    assert {:error, {:invalid_output, decoded}} = Invoke.call(manifest(dir), @input, policy(dir))
    assert decoded["emit"] == [%{"type" => "prompt"}]
  end

  test "bad shape: ok is not a boolean", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    echo '{"ok": "yes", "output": "", "emit": []}'
    """)

    assert {:error, {:invalid_output, _decoded}} = Invoke.call(manifest(dir), @input, policy(dir))
  end

  test "external commands require an execution policy", %{dir: dir} do
    assert {:error, :execution_context_required} = Invoke.call(manifest(dir), @input)
  end

  test "an external tool cannot modify its implementation directory", %{dir: dir} do
    workspace = Path.join(dir, "workspace")
    tool_dir = Path.join([workspace, "tools", "fixture"])
    File.mkdir_p!(tool_dir)

    write_run!(tool_dir, """
    #!/bin/sh
    touch "$PWD/changed" 2>/dev/null || true
    echo '{"ok": true, "output": "done", "emit": []}'
    """)

    policy =
      ExecutionPolicyFixtures.policy(workspace,
        writable: true,
        read_only: [tool_dir]
      )

    assert {:ok, %{output: "done"}} = Invoke.call(manifest(tool_dir), @input, policy)
    refute File.exists?(Path.join(tool_dir, "changed"))
  end

  describe "module path" do
    test "happy path calls module.run/1 and validates its result", %{dir: dir} do
      manifest = manifest(dir, %{command: nil, module: "Omunculus.Tools.Send"})
      input = %{@input | args: %{"message" => "hi"}}

      assert {:ok, result} = Invoke.call(manifest, input)

      assert result == %{
               ok: true,
               output: "",
               emit: [%{"type" => "prompt", "body" => %{"message" => "hi"}}]
             }
    end

    test "unknown module returns no_module", %{dir: dir} do
      manifest = manifest(dir, %{command: nil, module: "Omunculus.Tools.DoesNotExist"})

      assert Invoke.call(manifest, @input) ==
               {:error, {:no_module, "Omunculus.Tools.DoesNotExist"}}
    end

    test "module without run/1 returns no_module", %{dir: dir} do
      manifest = manifest(dir, %{command: nil, module: "Omunculus.Tool.Manifest"})

      assert Invoke.call(manifest, @input) == {:error, {:no_module, "Omunculus.Tool.Manifest"}}
    end
  end

  describe "the builtin send tool" do
    setup do
      [builtin_root | _] = Catalog.roots(".")
      catalog = Catalog.discover([builtin_root])
      %{manifest: Map.fetch!(catalog, "send")}
    end

    test "with a message returns ok and one prompt emit", %{manifest: manifest} do
      input = %{@input | name: "send", args: %{"message" => "count to 5"}}
      assert {:ok, result} = Invoke.call(manifest, input)

      assert result.ok == true

      assert result.emit == [
               %{"type" => "prompt", "body" => %{"message" => "count to 5"}}
             ]
    end

    test "without a message returns ok: false", %{manifest: manifest} do
      input = %{@input | name: "send", args: %{}}
      assert {:ok, %{ok: false}} = Invoke.call(manifest, input)
    end
  end

  defp policy(dir), do: ExecutionPolicyFixtures.policy(dir)
end
