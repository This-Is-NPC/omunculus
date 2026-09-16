defmodule Omunculus.Mcp do
  @moduledoc """
  A stdio JSON-RPC client for one MCP server exchange, per spec §8.7: spawns
  the server's `command` as a port, negotiates `initialize`, then either
  lists its tools or calls one, and closes the port. Each call is its own
  process: no server connection is kept between calls.
  """

  @protocol_version "2025-03-26"
  @timeout 10_000

  @type server :: %{name: String.t(), command: [String.t()]}

  @spec list_tools(server) ::
          {:ok, [%{name: String.t(), description: String.t(), parameters: map}]}
          | {:error, term}
  def list_tools(server) do
    with_session(server, fn port ->
      with {:ok, result} <- request(port, server, "tools/list", %{}) do
        {:ok, result |> Map.get("tools", []) |> Enum.map(&to_tool/1)}
      end
    end)
  end

  @spec call(server, String.t(), map) ::
          {:ok, %{ok: boolean, output: String.t(), emit: []}} | {:error, term}
  def call(server, name, args) do
    with_session(server, fn port ->
      with {:ok, result} <-
             request(port, server, "tools/call", %{name: name, arguments: args}) do
        {:ok, to_call_result(result)}
      end
    end)
  end

  defp with_session(server, fun) do
    with {:ok, port} <- open(server) do
      try do
        with :ok <- initialize(port, server), do: fun.(port)
      after
        close(port)
      end
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
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

  defp open(%{command: [program | args]} = server) do
    case System.find_executable(program) do
      nil ->
        {:error, {:mcp, server.name, :not_found}}

      path ->
        {:ok,
         Port.open({:spawn_executable, path}, [
           :binary,
           :exit_status,
           {:line, 1_048_576},
           args: args
         ])}
    end
  end

  defp initialize(port, server) do
    with {:ok, _result} <-
           request(port, server, "initialize", %{
             protocolVersion: @protocol_version,
             capabilities: %{},
             clientInfo: %{name: "omunculus", version: "0.1.0"}
           }) do
      notify(port, "notifications/initialized", %{})
    end
  end

  defp notify(port, method, params) do
    send_message(port, %{jsonrpc: "2.0", method: method, params: params})
  end

  defp request(port, server, method, params) do
    id = System.unique_integer([:positive, :monotonic])
    send_message(port, %{jsonrpc: "2.0", id: id, method: method, params: params})
    await(port, server, id)
  end

  defp send_message(port, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
    :ok
  end

  defp await(port, server, id) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        handle_line(port, server, id, Jason.decode(line))

      {^port, {:exit_status, status}} ->
        {:error, {:mcp, server.name, {:exit, status}}}
    after
      @timeout -> {:error, {:mcp, server.name, :timeout}}
    end
  end

  defp handle_line(_port, _server, id, {:ok, %{"id" => id, "result" => result}}),
    do: {:ok, result}

  defp handle_line(_port, server, id, {:ok, %{"id" => id, "error" => error}}),
    do: {:error, {:mcp, server.name, error}}

  defp handle_line(port, server, id, _other), do: await(port, server, id)
end
