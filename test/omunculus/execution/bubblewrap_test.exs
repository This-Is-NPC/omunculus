defmodule Omunculus.Execution.BubblewrapTest do
  use ExUnit.Case, async: false

  alias Omunculus.Id
  alias Omunculus.Execution.{Bubblewrap, Command, Policy}

  setup do
    workspace = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
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
      read_only: [],
      read_write: [workspace],
      hidden: Keyword.get(overrides, :hidden, []),
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
      tools: []
    }
  end
end
