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
    input = %{@input | args: %{"command" => "(exit 3)"}, roots: [root]}

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

  test "says the network is closed when a command cannot reach a host, even this machine",
       %{root: root} do
    for script <- [
          ~s|python3 -c "import socket; socket.gethostbyname('pypi.org')"|,
          ~s|python3 -c "import socket; socket.create_connection(('127.0.0.1', 9))"|
        ] do
      input = %{@input | args: %{"command" => script}, roots: [root]}

      assert %{"ok" => false, "output" => output} =
               Bash.run(input, policy(root, network: "none"))

      assert String.ends_with?(output, Out.closed_network()), script
    end
  end

  test "refuses without a command", %{root: root} do
    input = %{@input | args: %{}, roots: [root]}

    assert Bash.run(input, policy(root)) == %{
             "ok" => false,
             "output" => "command required",
             "emit" => []
           }
  end

  test "the commands of a run share one shell", %{root: root} do
    File.mkdir_p!(Path.join(root, "sub"))
    policy = policy(root)

    assert %{"ok" => true} =
             run(policy, root, %{"command" => "cd sub; X=kept; f() { echo fn; }"})

    assert %{"output" => output} = run(policy, root, %{"command" => "pwd; echo $X; f"})
    assert output == Path.join(root, "sub") <> "\nkept\nfn\n"

    assert %{"output" => output} = run(policy, root, %{"command" => "pwd", "workdir" => "."})
    assert String.trim(output) == root
  end

  test "a syntax error fails the call and the shell goes on", %{root: root} do
    policy = policy(root)
    run(policy, root, %{"command" => "X=1"})

    assert %{"ok" => false, "output" => output} = run(policy, root, %{"command" => "if then"})
    assert output =~ "syntax error"
    assert %{"output" => "1\n"} = run(policy, root, %{"command" => "echo $X"})
  end

  test "a command past its timeout is killed and the shell stays usable", %{root: root} do
    policy = policy(root)
    run(policy, root, %{"command" => "X=kept"})

    {micros, result} =
      :timer.tc(fn ->
        run(policy, root, %{"command" => "echo before; sleep 30", "timeout_ms" => 300})
      end)

    assert %{"ok" => false, "output" => output} = result
    assert output =~ "before\n"
    assert output =~ "ran past its timeout of 300 ms and was killed"
    assert output =~ "The shell is still open"
    assert micros < 5_000_000
    assert %{"ok" => true, "output" => "kept\n"} = run(policy, root, %{"command" => "echo $X"})
  end

  test "a command that holds the shell itself is killed with it", %{root: root} do
    policy = policy(root)
    run(policy, root, %{"command" => "X=kept"})

    assert %{"ok" => false, "output" => output} =
             run(policy, root, %{"command" => "while :; do :; done", "timeout_ms" => 200})

    assert output =~ "the next command starts a new shell"
    assert %{"ok" => true, "output" => "\n"} = run(policy, root, %{"command" => "echo $X"})
  end

  test "a timeout longer than the policy allows is refused", %{root: root} do
    policy = policy(root)

    assert %{
             "ok" => false,
             "output" => "timeout_ms is more than this project allows: at most 5000"
           } = run(policy, root, %{"command" => "true", "timeout_ms" => 5_001})

    for timeout <- [0, -1, "1000"] do
      assert %{"ok" => false} = run(policy, root, %{"command" => "true", "timeout_ms" => timeout})
    end
  end

  test "a command that exits ends the shell and the next starts another", %{root: root} do
    policy = policy(root)
    run(policy, root, %{"command" => "X=kept"})

    assert %{"ok" => false, "output" => output} = run(policy, root, %{"command" => "exit 4"})
    assert output =~ "ended the shell (exit 4)"
    assert %{"ok" => true, "output" => "\n"} = run(policy, root, %{"command" => "echo $X"})
  end

  test "output past the limit is cut", %{root: root} do
    policy = policy(root)

    assert %{"ok" => true, "output" => output} =
             run(policy, root, %{"command" => "head -c 5000 /dev/zero | tr '\\0' x"})

    assert String.starts_with?(output, String.duplicate("x", 1_024) <> "\n(the output went past")
    assert %{"ok" => true, "output" => "hi\n"} = run(policy, root, %{"command" => "echo hi"})
  end

  test "the shell ends with the process of the run", %{root: root} do
    policy = policy(root)
    parent = self()

    owner =
      spawn(fn ->
        run(policy, root, %{"command" => "true"})
        send(parent, :ran)
        Process.sleep(:infinity)
      end)

    assert_receive :ran, 5_000
    [{shell, _}] = Registry.lookup(Omunculus.Tool.Resident.Registry, {policy.id, "bash"})
    monitor = Process.monitor(shell)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^shell, _}, 5_000
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

  # A policy of its own run: its scratch, so its own shell.
  defp run(policy, root, args),
    do:
      Bash.run(
        %{@input | args: args, roots: [root], view: %{"bash" => %{"max_timeout_ms" => 5_000}}},
        policy
      )

  defp policy(root, overrides \\ []) do
    scratch = Omunculus.Fixtures.tmp_dir()

    %Policy{
      id: "bash-test-policy-" <> scratch,
      scratch: scratch,
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
        max_concurrent: 64,
        max_queue: 1,
        queue_timeout_ms: 100
      },
      tools: ["bash"],
      sandbox: ExecutionPolicyFixtures.sandbox()
    }
  end
end
