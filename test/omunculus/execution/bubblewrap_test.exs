defmodule Omunculus.Execution.BubblewrapTest do
  use ExUnit.Case, async: false

  alias Omunculus.Execution.{Bubblewrap, Command, Policy}
  alias Omunculus.ExecutionPolicyFixtures

  setup do
    workspace = Omunculus.Fixtures.tmp_dir()
    %{workspace: workspace}
  end

  test "runs a shell with incremental input and separate standard streams", %{
    workspace: workspace
  } do
    {:ok, command} =
      Command.new("/usr/bin/sh", [
        "-c",
        "read value; printf output:$value; printf error:$value >&2"
      ])

    assert {:ok, %{stdout: "output:hello", stderr: "error:hello", status: 0}} =
             Omunculus.Execution.run(command, policy(workspace), "hello\n")
  end

  test "a run's scratch is the /tmp and home every command of it shares, outside the workspace",
       %{workspace: workspace} do
    scratch = Omunculus.Fixtures.tmp_dir()
    policy = Policy.with_scratch(policy(workspace), scratch)

    run = fn script ->
      Omunculus.Execution.run(elem(Command.new("/usr/bin/sh", ["-c", script]), 1), policy)
    end

    assert {:ok, %{status: 0}} = run.("echo kept > /tmp/note && echo home > $HOME/profile")
    assert {:ok, %{stdout: "kept\nhome\n"}} = run.("cat /tmp/note $HOME/profile")
    assert File.read!(Path.join(scratch, "note")) == "kept\n"
    assert File.ls!(workspace) == []

    assert {:ok, %{stdout: ""}} =
             Omunculus.Execution.run(
               elem(Command.new("/usr/bin/sh", ["-c", "ls /tmp | grep note || true"]), 1),
               policy(workspace)
             )
  end

  test "a command that sees the host reads it as the person does and writes only where let",
       %{workspace: workspace} do
    home = System.user_home!()
    mark = Path.join(home, ".omunculus-host-test-#{System.unique_integer([:positive])}")
    secret = mark <> "-secret"
    File.write!(mark, "seen\n")
    File.write!(secret, "kept\n")
    on_exit(fn -> File.rm(mark) && File.rm(secret) end)

    scratch = Omunculus.Fixtures.tmp_dir()

    host = fn overrides ->
      Policy.with_scratch(policy(workspace, [host: true] ++ overrides), scratch)
    end

    run = fn policy, script ->
      Omunculus.Execution.run(elem(Command.new("/usr/bin/sh", ["-c", script]), 1), policy)
    end

    # The person's files read as they are; their home takes writes that stay
    # in the run's scratch.
    writing = host.(hidden: [secret])
    assert {:ok, %{stdout: "seen\n"}} = run.(writing, "cat #{mark}")

    assert {:ok, %{stdout: "home\n"}} =
             run.(writing, "echo home > #{mark}-new && cat #{mark}-new")

    refute File.exists?(mark <> "-new")
    assert File.exists?(Path.join([scratch, ".home", Path.basename(mark) <> "-new"]))

    # Elsewhere nothing is written, a denied path is not there, nor /run.
    assert {:ok, %{stdout: "refused\n"}} =
             run.(writing, "touch /etc/omunculus-test 2>/dev/null || echo refused")

    assert {:ok, %{stdout: "gone\n"}} =
             run.(writing, "cat #{secret} 2>/dev/null | grep -q kept || echo gone")

    assert {:ok, %{stdout: "\n"}} = run.(writing, "ls /run | grep -v systemd; echo")

    # Without sandbox.write the workspace stays read-only, under the home too.
    reading = host.(read_only: [workspace], read_write: [])

    assert {:ok, %{stdout: "refused\n"}} =
             run.(reading, "touch #{workspace}/x 2>/dev/null || echo refused")

    assert {:ok, %{stdout: "written\n"}} = run.(writing, "touch #{workspace}/x && echo written")
    assert File.exists?(Path.join(workspace, "x"))
  end

  test "a sandbox that cannot start says so and leaves no process waiting on its input", %{
    workspace: workspace
  } do
    writers = fn ->
      {said, _status} = System.cmd("pgrep", ["-f", "omunculus-input"])
      said |> String.split() |> length()
    end

    before = writers.()
    {:ok, command} = Command.new("/usr/bin/sh", ["-c", "true"], cwd: workspace)
    policy = policy(workspace, read_only: ["/nonexistent-omunculus-path"])

    assert {:error, {:bubblewrap, :setup_failed}} = Omunculus.Execution.run(command, policy)
    assert writers.() <= before
  end

  test "runs Python from the declared runtime", %{workspace: workspace} do
    {:ok, command} = Command.new("/usr/bin/python3", ["-c", "print('python')"])

    assert {:ok, %{stdout: "python\n", stderr: "", status: 0}} =
             Omunculus.Execution.run(command, policy(workspace))
  end

  test "masks a protected file after the writable workspace mount", %{workspace: workspace} do
    secret = Path.join(workspace, "secret")
    File.write!(secret, "private")

    {:ok, command} =
      Command.new("/usr/bin/sh", [
        "-c",
        "test \"$(cat #{secret})\" = \"\" && ! printf changed > #{secret}"
      ])

    assert {:ok, %{status: 0}} =
             Omunculus.Execution.run(command, policy(workspace, hidden: [secret]))

    assert File.read!(secret) == "private"
  end

  test "prevents creating a protected path that did not exist before the run", %{
    workspace: workspace
  } do
    protected = Path.join(workspace, "protected")
    {:ok, command} = Command.new("/usr/bin/sh", ["-c", "! printf data > #{protected}"])

    assert {:ok, %{status: 0}} =
             Omunculus.Execution.run(command, policy(workspace, hidden: [protected]))

    refute File.exists?(protected)
  end

  test "does not inherit undeclared host environment variables", %{workspace: workspace} do
    name = "OMUNCULUS_EXECUTION_TEST_SECRET"
    previous = System.get_env(name)
    System.put_env(name, "host-secret")

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)

    {:ok, command} = Command.new("/usr/bin/sh", ["-c", "printf %s \"${#{name}-unset}\""])

    assert {:ok, %{stdout: "unset"}} = Omunculus.Execution.run(command, policy(workspace))
  end

  test "hands a secret to its process alone, as a read-only file named by <NAME>_FILE", %{
    workspace: workspace
  } do
    script =
      ~s{printf "%s|%s|" "$GH_TOKEN_FILE" "$(cat "$GH_TOKEN_FILE")"; } <>
        ~s{stat -c %a "$GH_TOKEN_FILE"; ! printf x > "$GH_TOKEN_FILE"}

    {:ok, command} =
      Command.new("/usr/bin/sh", ["-c", script], secrets: %{"GH_TOKEN" => "token-value"})

    assert {:ok, %{stdout: "/run/secrets/GH_TOKEN|token-value|400\n", status: 0}} =
             Omunculus.Execution.run(command, policy(workspace))

    {:ok, other} = Command.new("/usr/bin/sh", ["-c", "test ! -e /run/secrets && printf none"])
    assert {:ok, %{stdout: "none"}} = Omunculus.Execution.run(other, policy(workspace))

    assert Path.wildcard(Path.join(System.tmp_dir!(), "omunculus-execution-*/secrets")) == []
  end

  test "never shows a command's secrets when it is inspected" do
    {:ok, command} = Command.new("/usr/bin/true", [], secrets: %{"GH_TOKEN" => "token-value"})
    refute inspect(command) =~ "token-value"
  end

  test "refuses a secret whose name is not a variable's" do
    assert {:error, :invalid_command} =
             Command.new("/usr/bin/true", [], secrets: %{"GH-TOKEN" => "token-value"})
  end

  test "cancels the Bubblewrap process tree on timeout", %{workspace: workspace} do
    marker = Path.join(workspace, "late-marker")
    {:ok, command} = Command.new("/usr/bin/sh", ["-c", "sleep 1; touch #{marker}"])

    assert {:error, :timeout} =
             Omunculus.Execution.run(command, policy(workspace, timeout_ms: 25))

    Process.sleep(100)
    refute File.exists?(marker)
  end

  test "builds a rootless Bubblewrap command and selects network namespaces from policy", %{
    workspace: workspace
  } do
    {:ok, command} = Command.new("/usr/bin/sh", ["-c", "true"])

    host_args =
      Bubblewrap.arguments(command, policy(workspace), Path.join(workspace, "temporary"))

    none_args =
      Bubblewrap.arguments(
        command,
        policy(workspace, network: "none"),
        Path.join(workspace, "temporary")
      )

    assert "--unshare-all" in host_args
    assert "--share-net" in host_args
    refute "--share-net" in none_args

    refute Enum.chunk_every(host_args, 3, 1, :discard)
           |> Enum.any?(&(&1 == ["--ro-bind", "/", "/"]))

    # With the network, a process can name hosts and trust certificates.
    resolver = ["--ro-bind-try", "/etc/resolv.conf", "/etc/resolv.conf"]
    assert resolver in Enum.chunk_every(host_args, 3, 1, :discard)
    refute resolver in Enum.chunk_every(none_args, 3, 1, :discard)
  end

  test "uses the runner from the policy", %{workspace: workspace} do
    {:ok, command} = Command.new("/usr/bin/sh", ["-c", "true"])
    runner = "exit 0"

    args =
      Bubblewrap.arguments(
        command,
        policy(workspace, sandbox: ExecutionPolicyFixtures.sandbox(runner: runner)),
        Path.join(workspace, "temporary")
      )

    assert runner in args
  end

  test "reports a setup failure when the runner did not write an exit status", %{
    workspace: workspace
  } do
    temp_dir = Path.join(workspace, "temporary")
    File.mkdir_p!(temp_dir)
    File.write!(Path.join(temp_dir, "status"), "")

    handle = %Bubblewrap.Handle{
      port: nil,
      input: nil,
      input_pid: nil,
      stderr_reader: nil,
      temp_dir: temp_dir,
      created_hidden: []
    }

    assert {:error, {:bubblewrap, :setup_failed}} = Bubblewrap.exit_status(handle, 0)
  end

  defp policy(workspace, overrides \\ []) do
    %Policy{
      id: "test-policy",
      workspace: %{name: nil, root: workspace},
      read_only: Keyword.get(overrides, :read_only, []),
      read_write: Keyword.get(overrides, :read_write, [workspace]),
      hidden: Keyword.get(overrides, :hidden, []),
      host: Keyword.get(overrides, :host, false),
      runtimes: ["/usr"],
      backend: "bubblewrap",
      environment: %{"LANG" => "C"},
      network: Keyword.get(overrides, :network, "host"),
      limits: %{
        timeout_ms: Keyword.get(overrides, :timeout_ms, 2_000),
        max_output_bytes: 1_024,
        max_concurrent: 1,
        max_queue: 1,
        queue_timeout_ms: 100
      },
      tools: [],
      sandbox: Keyword.get(overrides, :sandbox, ExecutionPolicyFixtures.sandbox())
    }
  end
end
