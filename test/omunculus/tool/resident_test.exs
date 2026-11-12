defmodule Omunculus.Tool.ResidentTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.{Invoke, Manifest, Resident}

  # Every answer carries how many lines this process has read.
  @script """
  #!/bin/sh
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    printf '{"ok": true, "output": "%s"}\\n' "$n"
  done
  """

  setup do
    dir = Omunculus.Fixtures.tmp_dir()
    File.write!(Path.join(dir, "run"), @script)
    File.chmod!(Path.join(dir, "run"), 0o755)
    %{dir: dir, policy: ExecutionPolicyFixtures.policy(dir)}
  end

  defp manifest(dir, keep_alive_ms),
    do: %Manifest{
      name: "resident-#{System.unique_integer([:positive])}",
      kind: "tool",
      command: ["./run"],
      dir: dir,
      keep_alive_ms: keep_alive_ms
    }

  defp call(manifest, policy, run_id) do
    input = %{
      name: manifest.name,
      args: %{},
      view: %{},
      run_id: run_id,
      roots: [],
      workspace: "."
    }

    {:ok, %{output: output}} = Invoke.call(manifest, input, policy)
    output |> String.split(":") |> List.last() |> String.to_integer()
  end

  test "the calls of a run reach one process", %{dir: dir, policy: policy} do
    manifest = manifest(dir, 60_000)

    assert call(manifest, policy, "run-a") == 1
    assert call(manifest, policy, "run-a") == 2
  end

  test "another run starts its own process", %{dir: dir, policy: policy} do
    manifest = manifest(dir, 60_000)

    assert call(manifest, policy, "run-a") == 1
    assert call(manifest, policy, "run-b") == 1
  end

  test "a call outside a run is served by a process of its own", %{dir: dir, policy: policy} do
    manifest = manifest(dir, 60_000)

    assert call(manifest, policy, nil) == 1
    assert call(manifest, policy, nil) == 1
  end

  test "a tool without keep_alive_ms starts a process per call", %{dir: dir, policy: policy} do
    manifest = manifest(dir, nil)

    assert call(manifest, policy, "run-a") == 1
    assert call(manifest, policy, "run-a") == 1
  end

  test "the process ends after its idle time and the next call starts another", %{
    dir: dir,
    policy: policy
  } do
    manifest = manifest(dir, 50)
    key = {"run-a", manifest.name}

    assert call(manifest, policy, "run-a") == 1
    assert wait_until(fn -> Registry.lookup(Omunculus.Tool.Resident.Registry, key) == [] end)
    assert call(manifest, policy, "run-a") == 1
  end

  test "a process that exits fails the call and the next call starts another", %{
    dir: dir,
    policy: policy
  } do
    File.write!(Path.join(dir, "run"), "#!/bin/sh\nread line\nexit 3\n")
    manifest = manifest(dir, 60_000)

    input = %{
      name: manifest.name,
      args: %{},
      view: %{},
      run_id: "run-a",
      roots: [],
      workspace: "."
    }

    assert {:error, {:exit, 3, _stderr}} = Invoke.call(manifest, input, policy)

    File.write!(Path.join(dir, "run"), @script)
    assert call(manifest, policy, "run-a") == 1
  end

  test "a call past its timeout stops a process that does not answer", %{
    dir: dir,
    policy: policy
  } do
    {:ok, command} =
      Omunculus.Execution.Command.new("/usr/bin/sh", ["-c", "read line; sleep 30"], cwd: dir)

    key = {"run-a", "slow"}

    assert {:error, :timeout} = Resident.call(key, command, "{}", policy, timeout_ms: 100)
    assert wait_until(fn -> Registry.lookup(Resident.Registry, key) == [] end)
  end

  test "the process ends with the process that started it, without keep_alive_ms", %{
    dir: dir,
    policy: policy
  } do
    {:ok, command} =
      Omunculus.Execution.Command.new("/usr/bin/sh", ["-c", "while read l; do echo ok; done"],
        cwd: dir
      )

    key = {"run-a", "owned"}
    parent = self()

    owner =
      spawn(fn ->
        send(parent, Resident.call(key, command, "{}", policy, []))
        Process.sleep(:infinity)
      end)

    assert_receive {:ok, _answer}, 5_000
    assert [{_pid, _}] = Registry.lookup(Resident.Registry, key)
    Process.exit(owner, :kill)
    assert wait_until(fn -> Registry.lookup(Resident.Registry, key) == [] end)
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
