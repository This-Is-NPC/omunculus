defmodule Omunculus.Tools.BashTest do
  use ExUnit.Case, async: true

  alias Omunculus.Execution.Policy
  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.{Catalog, Invoke, Manifest}
  alias Omunculus.Tools.{Bash, Out}

  setup do
    root = Omunculus.Fixtures.tmp_dir()
    %{root: root}
  end

  @input %{
    name: "bash",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "runs a command at the root and captures its output", %{root: root} do
    input = %{@input | args: %{"command" => "echo hi"}, roots: [root]}

    assert Bash.run(input, policy(root)) == %{"ok" => true, "output" => "hi\n", "emit" => []}
  end

  test "uses the trusted workspace instead of the public roots", %{root: root} do
    File.write!(Path.join(root, "marker"), "")
    input = %{@input | args: %{"command" => "ls"}, roots: []}

    assert %{"ok" => true, "output" => output} = Bash.run(input, policy(root))
    assert output =~ "marker"
  end

  test "starts in workdir, under the workspace root, and refuses one it cannot read", %{
    root: root
  } do
    File.mkdir_p!(Path.join(root, "sub"))
    input = %{@input | args: %{"command" => "pwd", "workdir" => "sub"}, roots: [root]}

    assert %{"ok" => true, "output" => output} = Bash.run(input, policy(root))
    assert String.trim(output) == Path.join(root, "sub")

    for workdir <- ["missing", "/proc/1", 3] do
      input = %{@input | args: %{"command" => "pwd", "workdir" => workdir}, roots: [root]}
      assert %{"ok" => false, "output" => "workdir " <> _} = Bash.run(input, policy(root))
    end
  end

  test "a non-zero exit fails and appends the exit status", %{root: root} do
    input = %{@input | args: %{"command" => "exit 3"}, roots: [root]}

    assert Bash.run(input, policy(root)) == %{
             "ok" => false,
             "output" => "\n(exit 3)",
             "emit" => []
           }
  end

  test "does not write without sandbox.write", %{root: root} do
    target = Path.join(root, "target")
    input = %{@input | args: %{"command" => "touch #{target}"}, roots: [root]}

    assert %{"ok" => false, "output" => output} =
             Bash.run(input, policy(root, read_only: [root], read_write: []))

    # The model learns why, and what would let it.
    assert String.ends_with?(output, Out.read_only_workspace())
    refute File.exists?(target)
  end

  test "says why a write failed even when the command exits 0", %{root: root} do
    target = Path.join(root, "target")
    input = %{@input | args: %{"command" => "touch #{target}; ls"}, roots: [root]}

    assert %{"ok" => true, "output" => output} =
             Bash.run(input, policy(root, read_only: [root], read_write: []))

    assert String.ends_with?(output, Out.read_only_workspace())
  end

  test "says the network is closed when a command cannot reach a host", %{root: root} do
    script = ~s|python3 -c "import socket; socket.gethostbyname('pypi.org')"|
    input = %{@input | args: %{"command" => script}, roots: [root]}

    assert %{"ok" => false, "output" => output} =
             Bash.run(input, policy(root, network: "none"))

    assert String.ends_with?(output, Out.closed_network())
  end

  test "refuses without a command", %{root: root} do
    input = %{@input | args: %{}, roots: [root]}

    assert Bash.run(input, policy(root)) == %{
             "ok" => false,
             "output" => "command required",
             "emit" => []
           }
  end

  test "the builtin catalog never discovers bash" do
    catalog = Catalog.unconfigured()

    refute Map.has_key?(catalog, "bash")
  end

  test "the codex-like preset's manifest wires bash to this module", %{root: root} do
    path = Path.join(:code.priv_dir(:omunculus), "presets/codex-like/tools/bash/tool.toml")

    assert {:ok, manifest} = Manifest.load(path)
    assert manifest.name == "bash"
    assert manifest.module == "Omunculus.Tools.Bash"
    assert manifest.triggers == ["model"]

    input = %{@input | args: %{"command" => "echo hi"}, roots: [root]}

    assert {:error, :execution_context_required} = Invoke.call(manifest, input)
    assert {:ok, result} = Invoke.call(manifest, input, policy(root))
    assert result.output == Bash.run(input, policy(root))["output"]
  end

  defp policy(root, overrides \\ []) do
    %Policy{
      id: "bash-test-policy",
      workspace: %{name: nil, root: root},
      read_only: Keyword.get(overrides, :read_only, []),
      read_write: Keyword.get(overrides, :read_write, [root]),
      hidden: [],
      runtimes: ["/usr"],
      backend: "bubblewrap",
      environment: %{"LANG" => "C"},
      network: Keyword.get(overrides, :network, "host"),
      limits: %{
        timeout_ms: 2_000,
        max_output_bytes: 1_024,
        max_concurrent: 1,
        max_queue: 1,
        queue_timeout_ms: 100
      },
      tools: ["bash"],
      sandbox: ExecutionPolicyFixtures.sandbox()
    }
  end
end
