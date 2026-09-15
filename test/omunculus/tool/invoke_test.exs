defmodule Omunculus.Tool.InvokeTest do
  use ExUnit.Case, async: true

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

    assert {:ok, result} = Invoke.call(manifest(dir), @input)

    assert result == %{
             ok: true,
             output: "done",
             emit: [%{"type" => "prompt", "body" => %{"message" => "hi"}}]
           }
  end

  test "input reaches stdin", %{dir: dir} do
    write_run!(dir, """
    #!/usr/bin/env -S LC_ALL=C LANG=C ELIXIR_ERL_OPTIONS=+fnu elixir
    input = IO.binread(:stdio, :eof)
    decoded = :json.decode(input)
    args = Map.get(decoded, "args", %{})
    result = %{ok: true, output: "", emit: [%{type: "echo", body: args}]}

    result
    |> :json.encode()
    |> IO.iodata_to_binary()
    |> :binary.bin_to_list()
    |> IO.write()
    """)

    input = %{@input | args: %{"message" => "conte até 5"}}
    assert {:ok, result} = Invoke.call(manifest(dir), input)
    assert result.emit == [%{"type" => "echo", "body" => %{"message" => "conte até 5"}}]
  end

  test "emit defaults to [] and output defaults to \"\"", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    echo '{"ok": true}'
    """)

    assert {:ok, %{ok: true, output: "", emit: []}} = Invoke.call(manifest(dir), @input)
  end

  test "non-zero exit returns the exit error", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    echo 'boom' >&1
    exit 3
    """)

    assert {:error, {:exit, 3, "boom\n"}} = Invoke.call(manifest(dir), @input)
  end

  test "non-JSON stdout is rejected", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    echo 'not json'
    """)

    assert {:error, {:invalid_output, "not json\n"}} = Invoke.call(manifest(dir), @input)
  end

  test "bad shape: emit entry without body is rejected", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    echo '{"ok": true, "output": "", "emit": [{"type": "prompt"}]}'
    """)

    assert {:error, {:invalid_output, decoded}} = Invoke.call(manifest(dir), @input)
    assert decoded["emit"] == [%{"type" => "prompt"}]
  end

  test "bad shape: ok is not a boolean", %{dir: dir} do
    write_run!(dir, """
    #!/bin/sh
    echo '{"ok": "yes", "output": "", "emit": []}'
    """)

    assert {:error, {:invalid_output, _decoded}} = Invoke.call(manifest(dir), @input)
  end

  describe "module path" do
    test "happy path calls module.run/1 and validates its result", %{dir: dir} do
      manifest = manifest(dir, %{command: nil, module: "Omunculus.Tools.Send"})
      input = %{@input | args: %{"message" => "oi"}}

      assert {:ok, result} = Invoke.call(manifest, input)

      assert result == %{
               ok: true,
               output: "",
               emit: [%{"type" => "prompt", "body" => %{"message" => "oi"}}]
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
      input = %{@input | name: "send", args: %{"message" => "conte até 5"}}
      assert {:ok, result} = Invoke.call(manifest, input)

      assert result.ok == true

      assert result.emit == [
               %{"type" => "prompt", "body" => %{"message" => "conte até 5"}}
             ]
    end

    test "without a message returns ok: false", %{manifest: manifest} do
      input = %{@input | name: "send", args: %{}}
      assert {:ok, %{ok: false}} = Invoke.call(manifest, input)
    end
  end
end
