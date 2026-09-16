defmodule Omunculus.OpenAIStub do
  @moduledoc """
  Builds and drives the Rust binary at `test/support/openai_stub` for
  `Omunculus.Model.OpenAI` tests: an OpenAI-compatible
  `/v1/chat/completions` server that, while a request carries a
  `counter` tool and fewer `tool` messages than its configured
  `tool_rounds`, replies with a `counter` tool call; otherwise it replies
  with the content `"benchmark complete"`. `GET /stats` reports counters
  plus `last_tools`, the `name`/`parameters` of the functions declared on
  the most recently received request.
  """

  @default_timeout 10_000

  @spec start(keyword) :: {:ok, map} | {:error, term}
  def start(opts \\ []) do
    with {:ok, executable} <- build_executable(),
         {:ok, {port, os_pid}} <- open_port(executable) do
      case await_ready(port, os_pid, <<>>, Keyword.get(opts, :timeout, @default_timeout)) do
        {:ok, stub} ->
          case configure(stub, opts) do
            :ok ->
              {:ok, stub}

            {:error, _reason} = error ->
              stop(stub)
              error
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec configure(map, keyword) :: :ok | {:error, term}
  def configure(%{base_url: base_url} = stub, opts) do
    payload =
      %{}
      |> put_option(opts, "tool_rounds", :tool_rounds)
      |> put_option(opts, "delay_ms", :delay_ms)

    case Req.post(base_url <> "/control",
           json: payload,
           receive_timeout: Keyword.get(opts, :timeout, Map.get(stub, :timeout, @default_timeout))
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:stub_control, status, body}}
      {:error, reason} -> {:error, {:stub_control, reason}}
    end
  end

  @spec stats(map) :: {:ok, map} | {:error, term}
  def stats(%{base_url: base_url} = stub) do
    case Req.get(base_url <> "/stats",
           receive_timeout: Map.get(stub, :timeout, @default_timeout)
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:stub_stats, status, body}}
      {:error, reason} -> {:error, {:stub_stats, reason}}
    end
  end

  @spec stop(map | nil) :: :ok
  def stop(nil), do: :ok

  def stop(%{port: port, os_pid: os_pid}) when is_port(port) do
    terminate(os_pid)
    close_port(port)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp build_executable do
    cargo = System.find_executable("cargo")
    source = Path.expand("openai_stub", __DIR__)

    cond do
      is_nil(cargo) ->
        {:error, {:stub_unavailable, :cargo}}

      not File.exists?(Path.join(source, "Cargo.toml")) ->
        {:error, {:stub_unavailable, Path.join(source, "Cargo.toml")}}

      true ->
        build(cargo, source)
    end
  rescue
    error -> {:error, {:stub_build_failed, Exception.message(error)}}
  end

  defp build(cargo, source) do
    fingerprint = fingerprint(source)
    cache = Path.join(System.tmp_dir!(), "omunculus-openai-stub")
    target_dir = Path.join(cache, "target-" <> fingerprint)
    binary = Path.join([target_dir, "release", binary_name()])

    if File.exists?(binary) do
      {:ok, binary}
    else
      File.mkdir_p!(target_dir)
      manifest = Path.join(source, "Cargo.toml")

      case System.cmd(
             cargo,
             ["build", "--release", "--manifest-path", manifest, "--target-dir", target_dir],
             cd: source,
             stderr_to_stdout: true,
             env: [{"CARGO_TERM_COLOR", "never"}]
           ) do
        {_output, 0} ->
          if File.exists?(binary),
            do: {:ok, binary},
            else: {:error, {:stub_binary_missing, binary}}

        {output, status} ->
          {:error, {:stub_build_failed, status, output}}
      end
    end
  end

  defp binary_name do
    if match?({:win32, _}, :os.type()), do: "openai_stub.exe", else: "openai_stub"
  end

  defp fingerprint(source) do
    files =
      source
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&(Path.basename(&1) == "Cargo.lock"))
      |> Enum.sort()

    digest =
      Enum.reduce(files, :crypto.hash_init(:sha256), fn file, context ->
        context
        |> :crypto.hash_update(Path.relative_to(file, source))
        |> :crypto.hash_update(File.read!(file))
      end)
      |> :crypto.hash_final()

    Base.encode16(digest, case: :lower)
  end

  defp open_port(executable) do
    try do
      port =
        Port.open(
          {:spawn_executable, executable},
          [:binary, :exit_status, :stderr_to_stdout, {:args, ["--port", "0"]}]
        )

      case port_pid(port) do
        {:ok, pid} ->
          {:ok, {port, pid}}

        {:error, reason} ->
          close_port(port)
          {:error, reason}
      end
    catch
      kind, reason -> {:error, {:stub_spawn_failed, kind, reason}}
    end
  end

  defp port_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> {:ok, pid}
      _ -> {:error, :stub_pid_unavailable}
    end
  end

  defp await_ready(port, os_pid, buffer, timeout) do
    receive do
      {^port, {:data, data}} ->
        buffer = buffer <> data

        case Regex.run(~r/(?:^|\n)READY\s+(\d+)/, buffer) do
          [_, port_number] ->
            {:ok,
             %{
               port: port,
               os_pid: os_pid,
               port_number: String.to_integer(port_number),
               base_url: "http://127.0.0.1:" <> port_number,
               timeout: timeout
             }}

          _ ->
            await_ready(port, os_pid, buffer, timeout)
        end

      {^port, {:exit_status, status}} ->
        close_port(port)
        {:error, {:stub_exit, status, buffer}}
    after
      timeout ->
        terminate(os_pid)
        close_port(port)
        {:error, :stub_timeout}
    end
  end

  defp put_option(payload, opts, json_key, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Map.put(payload, json_key, value)
      :error -> payload
    end
  end

  defp terminate(pid) when is_integer(pid) do
    _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp terminate(_), do: :ok

  defp close_port(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
    :exit, _ -> :ok
  end
end
