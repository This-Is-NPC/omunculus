defmodule Omunculus.Execution.Bubblewrap do
  @moduledoc """
  Runs commands in a Bubblewrap namespace with only the policy's mounts.
  """

  @behaviour Omunculus.Execution.Backend

  alias Omunculus.Id
  alias Omunculus.Path, as: FilesystemPath
  alias Omunculus.Execution.{Command, Policy}

  @minimum_version {0, 8, 0}
  @runner "input=$1; errors=$2; shift 2; exec \"$@\" < \"$input\" 2> \"$errors\""

  defmodule Handle do
    @moduledoc false
    @enforce_keys [:port, :input, :stderr_reader, :temp_dir, :created_hidden]
    defstruct @enforce_keys
  end

  @impl true
  def start(command, policy, owner, ref) do
    with {:ok, bwrap} <- executable(),
         :ok <- verify_version(bwrap),
         {:ok, command} <- validate_command(command, policy),
         {:ok, temp_dir} <- temporary_dir() do
      case start_in_temp(bwrap, command, policy, owner, ref, temp_dir) do
        {:ok, _handle} = result ->
          result

        {:error, _reason} = error ->
          File.rm_rf(temp_dir)
          error
      end
    end
  end

  defp start_in_temp(bwrap, command, policy, owner, ref, temp_dir) do
    with {:ok, created_hidden} <- prepare_hidden(policy, temp_dir) do
      case start_process(bwrap, command, policy, owner, ref, temp_dir, created_hidden) do
        {:ok, _handle} = result ->
          result

        {:error, _reason} = error ->
          cleanup_hidden(created_hidden)
          error
      end
    end
  end

  defp start_process(bwrap, command, policy, owner, ref, temp_dir, created_hidden) do
    with {:ok, input_guard} <- open_fifo(temp_dir, "input"),
         {:ok, stderr_reader} <- start_stderr_reader(temp_dir),
         {:ok, port} <- open_port(bwrap, command, policy, temp_dir),
         :ok <- close_file(input_guard),
         {:ok, input} <- start_input_writer(temp_dir, owner, ref) do
      {:ok,
       %Handle{
         port: port,
         input: input,
         stderr_reader: stderr_reader,
         temp_dir: temp_dir,
         created_hidden: created_hidden
       }}
    end
  end

  @impl true
  def write(%Handle{input: input}, data) do
    send(input, {:execution_input, :write, IO.iodata_to_binary(data)})
    :ok
  end

  @impl true
  def close_input(%Handle{input: input}) do
    send(input, {:execution_input, :close})
    :ok
  end

  @impl true
  def stop(%Handle{} = handle, _reason) do
    stop_input(handle.input)
    kill_port(handle.port)
    kill_port(handle.stderr_reader)
    cleanup_hidden(handle.created_hidden)
    :ok
  end

  @impl true
  def cleanup(%Handle{} = handle) do
    stop_input(handle.input)
    kill_port(handle.stderr_reader)
    cleanup_hidden(handle.created_hidden)
    File.rm_rf(handle.temp_dir)
    :ok
  end

  @spec arguments(Command.t(), Policy.t(), String.t()) :: [String.t()]
  def arguments(command, policy, temp_dir) do
    mounts = mounts(policy, temp_dir)

    ["--unshare-all", "--unshare-user"] ++
      network_args(policy.network) ++
      ["--die-with-parent", "--new-session", "--clearenv", "--tmpfs", "/"] ++
      base_filesystem_args() ++
      mount_args(mounts) ++
      hidden_args(policy.hidden, mounts, temp_dir) ++
      environment_args(policy, mounts) ++
      ["--chdir", command.cwd, "--", "/usr/bin/sh", "-c", @runner, "omunculus-exec"] ++
      [
        Path.join(temp_dir, "input"),
        Path.join(temp_dir, "stderr"),
        command.program | command.args
      ]
  end

  defp executable do
    case System.find_executable("bwrap") do
      nil -> {:error, :bubblewrap_unavailable}
      path -> {:ok, path}
    end
  end

  defp verify_version(path) do
    case System.cmd(path, ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        if supported_version?(output),
          do: :ok,
          else: {:error, {:bubblewrap, :unsupported_version}}

      {_output, _status} ->
        {:error, {:bubblewrap, :unavailable}}
    end
  rescue
    ErlangError -> {:error, :bubblewrap_unavailable}
  end

  defp supported_version?(output) do
    case Regex.run(~r/(\d+)\.(\d+)\.(\d+)/, output, capture: :all_but_first) do
      [major, minor, patch] ->
        {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)} >=
          @minimum_version

      _ ->
        false
    end
  end

  defp validate_command(%Command{} = command, policy) do
    with true <- Command.valid?(command),
         {:ok, program} <- canonical_file(command.program),
         true <- Enum.any?(policy.runtimes, &FilesystemPath.within?(&1, program)),
         cwd = command.cwd || policy.workspace.root,
         {:ok, cwd} <- canonical_directory(cwd),
         true <- FilesystemPath.within?(policy.workspace.root, cwd) do
      {:ok, %{command | program: program, cwd: cwd}}
    else
      false -> {:error, :command_outside_policy}
      {:error, reason} -> {:error, {:command, reason}}
    end
  end

  defp validate_command(_command, _policy), do: {:error, :invalid_command}

  defp canonical_file(path) do
    with {:ok, canonical} <- FilesystemPath.canonical(path),
         true <- File.regular?(canonical) do
      {:ok, canonical}
    else
      false -> {:error, :not_a_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_directory(path) do
    with {:ok, canonical} <- FilesystemPath.canonical(path),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      false -> {:error, :not_a_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp temporary_dir do
    path = Path.join(System.tmp_dir!(), "omunculus-execution-" <> Id.new())

    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, 0o700),
         :ok <- make_fifo(Path.join(path, "input")),
         :ok <- make_fifo(Path.join(path, "stderr")),
         :ok <- File.write(Path.join(path, "empty"), ""),
         :ok <- File.chmod(Path.join(path, "empty"), 0o444) do
      {:ok, path}
    else
      {:error, reason} ->
        File.rm_rf(path)
        {:error, {:temporary_directory, reason}}
    end
  end

  defp make_fifo(path) do
    case System.find_executable("mkfifo") do
      nil ->
        {:error, :mkfifo_unavailable}

      executable ->
        case System.cmd(executable, [path], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, _status} -> {:error, {:mkfifo, output}}
        end
    end
  rescue
    ErlangError -> {:error, :mkfifo_unavailable}
  end

  defp open_fifo(temp_dir, name) do
    case File.open(Path.join(temp_dir, name), [:read, :write, :binary]) do
      {:ok, device} -> {:ok, device}
      {:error, reason} -> {:error, {:fifo, reason}}
    end
  end

  defp start_input_writer(temp_dir, owner, ref) do
    path = Path.join(temp_dir, "input")

    Task.start(fn ->
      case File.open(path, [:write, :binary]) do
        {:ok, device} -> input_loop(device, owner, ref)
        {:error, reason} -> send(owner, {:execution, ref, {:error, {:input, reason}}})
      end
    end)
  end

  defp input_loop(device, owner, ref) do
    receive do
      {:execution_input, :write, data} ->
        case IO.binwrite(device, data) do
          :ok ->
            input_loop(device, owner, ref)

          {:error, reason} ->
            File.close(device)
            send(owner, {:execution, ref, {:error, {:input, reason}}})
        end

      {:execution_input, :close} ->
        File.close(device)
    end
  rescue
    exception ->
      File.close(device)
      send(owner, {:execution, ref, {:error, {:input, Exception.message(exception)}}})
  end

  defp start_stderr_reader(temp_dir) do
    path = Path.join(temp_dir, "stderr")

    case System.find_executable("cat") do
      nil ->
        {:error, :cat_unavailable}

      executable ->
        {:ok,
         Port.open({:spawn_executable, executable}, [
           :binary,
           :exit_status,
           args: [path]
         ])}
    end
  end

  defp open_port(bwrap, command, policy, temp_dir) do
    {:ok,
     Port.open({:spawn_executable, bwrap}, [
       :binary,
       :exit_status,
       args: arguments(command, policy, temp_dir)
     ])}
  rescue
    error in ArgumentError -> {:error, {:bubblewrap, Exception.message(error)}}
  end

  defp network_args("host"), do: ["--share-net"]
  defp network_args("none"), do: []

  defp base_filesystem_args do
    [
      "--dir",
      "/tmp",
      "--tmpfs",
      "/tmp",
      "--dir",
      "/tmp/home",
      "--tmpfs",
      "/tmp/home",
      "--proc",
      "/proc",
      "--dev",
      "/dev",
      "--symlink",
      "usr/bin",
      "/bin",
      "--symlink",
      "usr/lib",
      "/lib",
      "--symlink",
      "usr/lib",
      "/lib64",
      "--symlink",
      "usr/sbin",
      "/sbin"
    ]
  end

  defp mounts(policy, temp_dir) do
    policy.runtimes
    |> Enum.map(&{:read_only, &1, &1})
    |> Kernel.++(Enum.map(policy.read_only, &{:read_only, &1, &1}))
    |> Kernel.++(Enum.map(policy.read_write, &{:read_write, &1, &1}))
    |> Kernel.++([{:read_write, temp_dir, temp_dir}])
    |> Enum.reduce(%{}, fn {mode, source, destination}, mounts ->
      Map.update(mounts, destination, {mode, source, destination}, fn {existing_mode, _, _} ->
        if existing_mode == :read_write,
          do: {existing_mode, source, destination},
          else: {mode, source, destination}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(fn {_mode, _source, destination} -> {path_depth(destination), destination} end)
  end

  defp mount_args(mounts) do
    {directories, binds} =
      Enum.reduce(mounts, {MapSet.new(), []}, fn {mode, source, destination},
                                                 {directories, binds} ->
        directories =
          destination
          |> mount_directories(File.dir?(source))
          |> Enum.reduce(directories, &MapSet.put(&2, &1))

        bind =
          if mode == :read_only,
            do: ["--ro-bind", source, destination],
            else: ["--bind", source, destination]

        {directories, [bind | binds]}
      end)

    directory_args =
      directories |> Enum.sort_by(&{path_depth(&1), &1}) |> Enum.flat_map(&["--dir", &1])

    (directory_args ++ Enum.reverse(binds)) |> List.flatten()
  end

  defp hidden_args(hidden, mounts, temp_dir) do
    visible = fn hidden_path ->
      Enum.any?(mounts, fn {_mode, _source, destination} ->
        FilesystemPath.within?(destination, hidden_path)
      end)
    end

    hidden
    |> Enum.filter(visible)
    |> Enum.sort_by(&{path_depth(&1), &1})
    |> Enum.flat_map(fn path ->
      if File.dir?(path) do
        (mount_directories(path, true) |> Enum.flat_map(&["--dir", &1])) ++ ["--tmpfs", path]
      else
        ["--ro-bind", Path.join(temp_dir, "empty"), path]
      end
    end)
  end

  defp prepare_hidden(policy, temp_dir) do
    mounts = mounts(policy, temp_dir)

    result =
      policy.hidden
      |> Enum.filter(fn hidden ->
        Enum.any?(mounts, fn {_mode, _source, destination} ->
          FilesystemPath.within?(destination, hidden)
        end)
      end)
      |> Enum.reduce_while([], fn path, created ->
        if File.exists?(path) do
          {:cont, created}
        else
          case File.write(path, "") do
            :ok -> {:cont, [path | created]}
            {:error, reason} -> {:halt, {:error, path, reason, created}}
          end
        end
      end)

    case result do
      {:error, path, reason, created} ->
        cleanup_hidden(created)
        {:error, {:hidden_path, path, reason}}

      created ->
        {:ok, created}
    end
  end

  defp environment_args(policy, _mounts) do
    path =
      policy.runtimes
      |> Enum.map(&Path.join(&1, "bin"))
      |> Enum.filter(&File.dir?/1)
      |> Enum.uniq()
      |> Enum.join(":")

    ["--setenv", "HOME", "/tmp/home", "--setenv", "TMPDIR", "/tmp", "--setenv", "PATH", path] ++
      (policy.environment
       |> Enum.sort_by(fn {name, _value} -> name end)
       |> Enum.flat_map(fn {name, value} -> ["--setenv", name, value] end))
  end

  defp mount_directories(path, include_self?) do
    path = if include_self?, do: path, else: Path.dirname(path)

    path
    |> Path.split()
    |> Enum.reduce({"/", []}, fn part, {parent, directories} ->
      next = Path.join(parent, part)
      {next, [next | directories]}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == "/"))
  end

  defp path_depth(path), do: path |> Path.split() |> length()

  defp close_file(device) do
    File.close(device)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp stop_input(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp cleanup_hidden(paths) do
    Enum.each(paths, &File.rm/1)
  end

  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        :ok

      nil ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
