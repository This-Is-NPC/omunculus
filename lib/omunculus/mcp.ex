defmodule Omunculus.Mcp do
  @moduledoc """
  Exchanges JSON-RPC messages with one MCP server through the execution
  transport. Every discovery and call owns a short-lived sandboxed session.
  """

  alias Omunculus.Execution
  alias Omunculus.Execution.{Command, Policy}
  alias Omunculus.Path, as: FilesystemPath

  @protocol_version "2025-03-26"
  @runner ~s(exec "$@")

  @type server :: %{name: String.t(), command: [String.t()]}

  @spec list_tools(server, Policy.t()) ::
          {:ok, [%{name: String.t(), description: String.t(), parameters: map}]} | {:error, term}
  def list_tools(server, %Policy{} = policy) do
    with_session(server, policy, fn state ->
      with {:ok, result, _state} <- request(state, "tools/list", %{}) do
        {:ok, result |> Map.get("tools", []) |> Enum.map(&to_tool/1)}
      end
    end)
  end

  @spec call(server, String.t(), map, Policy.t()) ::
          {:ok, %{ok: boolean, output: String.t(), emit: []}} | {:error, term}
  def call(server, name, args, %Policy{} = policy) do
    with_session(server, policy, fn state ->
      with {:ok, result, _state} <- request(state, "tools/call", %{name: name, arguments: args}) do
        {:ok, to_call_result(result)}
      end
    end)
  end

  @spec implementation_roots([server]) :: [String.t()]
  def implementation_roots(servers) do
    servers
    |> Enum.flat_map(fn %{command: [program | _]} -> implementation_root(program) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp with_session(server, policy, fun) do
    with {:ok, command} <- command(server, policy) do
      case Execution.start(command, policy) do
        {:ok, handle} ->
          try do
            state = %{handle: handle, server: server, buffer: "", stderr: "", policy: policy}

            with {:ok, state} <- initialize(state), do: fun.(state)
          after
            stop(handle)
          end

        {:error, reason} ->
          {:error, {:mcp, server.name, {:execution, reason}}}
      end
    else
      {:error, {:mcp, reason}} -> {:error, {:mcp, server.name, reason}}
      {:error, _reason} = error -> error
    end
  end

  defp command(%{command: [program | args]}, policy) do
    with {:ok, executable} <- executable(program, policy),
         {:ok, command} <-
           Command.new(
             "/usr/bin/sh",
             ["-c", @runner, "omunculus-mcp", executable | args],
             cwd: Path.dirname(executable)
           ) do
      {:ok, command}
    end
  end

  defp command(_server, _policy), do: {:error, :invalid_command}

  defp initialize(state) do
    with {:ok, _result, state} <-
           request(state, "initialize", %{
             protocolVersion: @protocol_version,
             capabilities: %{},
             clientInfo: %{name: "omunculus", version: "0.1.0"}
           }),
         :ok <- notify(state, "notifications/initialized", %{}) do
      {:ok, state}
    end
  end

  defp notify(state, method, params) do
    send_message(state.handle, %{jsonrpc: "2.0", method: method, params: params})
  end

  defp request(state, method, params) do
    id = System.unique_integer([:positive, :monotonic])

    with :ok <-
           send_message(state.handle, %{jsonrpc: "2.0", id: id, method: method, params: params}) do
      await(state, id, deadline(state.policy))
    end
  end

  defp send_message(handle, message), do: Execution.write(handle, Jason.encode!(message) <> "\n")

  defp await(state, id, deadline) do
    case next_message(state) do
      {:ok, message, state} -> handle_message(state, id, message, deadline)
      :more -> receive_message(state, id, deadline)
      {:error, _reason} = error -> error
    end
  end

  defp handle_message(state, id, %{"id" => id, "result" => result}, _deadline),
    do: {:ok, result, state}

  defp handle_message(state, id, %{"id" => id, "error" => error}, _deadline),
    do: {:error, {:mcp, state.server.name, error}}

  defp handle_message(state, id, _message, deadline), do: await(state, id, deadline)

  defp receive_message(state, id, deadline) do
    receive do
      {:execution, ref, {:stdout, bytes}} when ref == state.handle.ref ->
        await(%{state | buffer: state.buffer <> bytes}, id, deadline)

      {:execution, ref, {:stderr, bytes}} when ref == state.handle.ref ->
        await(%{state | stderr: state.stderr <> bytes}, id, deadline)

      {:execution, ref, {:exit, status}} when ref == state.handle.ref ->
        {:error, {:mcp, state.server.name, {:exit, status}}}

      {:execution, ref, {:error, reason}} when ref == state.handle.ref ->
        {:error, {:mcp, state.server.name, {:execution, reason}}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, {:mcp, state.server.name, :timeout}}
    end
  end

  defp next_message(%{buffer: buffer} = state) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        case Jason.decode(line) do
          {:ok, message} when is_map(message) -> {:ok, message, %{state | buffer: rest}}
          _ -> {:error, {:mcp, state.server.name, :invalid_output}}
        end

      [_partial] ->
        :more
    end
  end

  defp executable(program, policy) do
    if Path.type(program) == :absolute or String.contains?(program, "/") do
      external_executable(program, policy)
    else
      runtime_executable(program, policy)
    end
  end

  defp external_executable(program, policy) do
    with {:ok, executable} <- canonical_file(program),
         true <- Policy.readable?(policy, executable) do
      {:ok, executable}
    else
      false -> {:error, :command_outside_policy}
      {:error, _reason} = error -> error
    end
  end

  defp runtime_executable(program, policy) do
    policy.runtimes
    |> Enum.map(&Path.join([&1, "bin", program]))
    |> Enum.find_value({:error, {:mcp, :not_found}}, fn path ->
      case canonical_file(path) do
        {:ok, executable} -> {:ok, executable}
        {:error, _reason} -> false
      end
    end)
  end

  defp implementation_root(program) do
    if Path.type(program) == :absolute or String.contains?(program, "/") do
      case canonical_file(program) do
        {:ok, executable} -> [Path.dirname(executable)]
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  defp canonical_file(path) do
    with {:ok, canonical} <- FilesystemPath.canonical(path),
         true <- File.regular?(canonical) do
      {:ok, canonical}
    else
      false -> {:error, {:mcp, :not_found}}
      {:error, reason} -> {:error, {:mcp, reason}}
    end
  end

  defp deadline(policy), do: System.monotonic_time(:millisecond) + policy.limits.timeout_ms

  defp stop(handle) do
    Execution.stop(handle, :completed)
  catch
    :exit, _reason -> :ok
  end

  defp to_tool(tool) do
    %{
      name: tool["name"],
      description: tool["description"] || "",
      parameters: tool["inputSchema"] || %{}
    }
  end

  defp to_call_result(result) do
    output =
      result
      |> Map.get("content", [])
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("\n")

    %{ok: !result["isError"], output: output, emit: []}
  end
end
