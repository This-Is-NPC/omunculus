defmodule Omunculus.Sandbox do
  @moduledoc "JavaScript tools.* bridge. Deno has no file, network, environment or process permissions."

  def run(code, tools, call, opts \\ []) when is_binary(code) do
    case System.find_executable("deno") do
      nil -> {:error, :deno_not_found}
      executable -> execute(executable, code, tools, call, Keyword.get(opts, :timeout, 10_000))
    end
  end

  defp execute(executable, code, tools, call, timeout) do
    script = Application.app_dir(:omunculus, "priv/sandbox.js")

    args =
      ~w(run --no-config --no-lock --no-prompt --cached-only --deny-read --deny-write --deny-net --deny-env --deny-run --deny-ffi --deny-sys --deny-import) ++
        [script]

    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args])

    try do
      send_json(port, %{code: code, names: Enum.map(tools, & &1.name)})
      allowed = MapSet.new(tools, & &1.name)

      authorized_call = fn name, args ->
        if MapSet.member?(allowed, name),
          do: call.(name, args),
          else: {:error, {:not_allowed, name}}
      end

      receive_output(port, "", authorized_call, System.monotonic_time(:millisecond) + timeout)
    after
      stop(port)
    end
  end

  defp receive_output(port, buffer, call, deadline) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        case Jason.decode(line) do
          {:ok, %{"type" => "call", "id" => id, "name" => name, "args" => args}}
          when is_binary(name) and is_map(args) ->
            response =
              case call.(name, args) do
                {:ok, output} -> %{id: id, ok: true, output: output}
                {:error, reason} -> %{id: id, ok: false, output: inspect(reason)}
              end

            send_json(port, response)
            receive_output(port, rest, call, deadline)

          {:ok, %{"type" => "result", "output" => output}} ->
            {:ok, output}

          {:ok, %{"type" => "error", "output" => output}} ->
            {:error, {:javascript, output}}

          _ ->
            {:error, :invalid_sandbox_output}
        end

      [_partial] ->
        receive do
          {^port, {:data, data}} -> receive_output(port, buffer <> data, call, deadline)
          {^port, {:exit_status, status}} -> {:error, {:sandbox_exit, status}}
        after
          max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :sandbox_timeout}
        end
    end
  end

  defp send_json(port, value), do: Port.command(port, Jason.encode!(value) <> "\n")

  defp stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
      nil -> :ok
    end

    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
