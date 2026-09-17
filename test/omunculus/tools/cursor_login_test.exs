defmodule Omunculus.Tools.CursorLoginTest do
  use ExUnit.Case, async: true

  @login Path.expand("priv/tools/cursor_login/run", File.cwd!())
  @refresh Path.expand("priv/tools/cursor_refresh/run", File.cwd!())

  test "cursor_login polls a fake server and prints a credential" do
    {:ok, server} = start_server()
    on_exit(fn -> stop_server(server) end)
    base = "http://127.0.0.1:#{server.port}"

    {stdout, 0} =
      System.cmd(
        "sh",
        ["-c", "python3 \"$1\" < /dev/null", "omunculus-login", @login],
        env: [
          {"OMUNCULUS_CURSOR_LOGIN_URL", base <> "/loginDeepControl"},
          {"OMUNCULUS_CURSOR_POLL_URL", base <> "/auth/poll"},
          {"OMUNCULUS_CURSOR_EXCHANGE_URL", base <> "/auth/exchange_user_api_key"},
          {"OMUNCULUS_CURSOR_NO_BROWSER", "1"},
          {"OMUNCULUS_CURSOR_POLL_SECONDS", "5"}
        ],
        stderr_to_stdout: true
      )

    assert {:ok, %{"ok" => true, "output" => output, "emit" => []}} = Jason.decode(stdout)
    assert {:ok, cred} = Jason.decode(output)
    assert cred["access"] == "exchanged-access"
    assert cred["refresh"] == "refresh-token"
  end

  test "cursor_refresh exchanges the stored key on a fake server" do
    {:ok, server} = start_server()
    on_exit(fn -> stop_server(server) end)
    base = "http://127.0.0.1:#{server.port}"

    input =
      Jason.encode!(%{
        "view" => %{
          "credential" => %{
            "access" => "old",
            "refresh" => "refresh-token",
            "expires_at" => "2020-01-01T00:00:00Z"
          }
        }
      })

    in_path =
      Path.join(
        System.tmp_dir!(),
        "omunculus-cursor-refresh-#{System.unique_integer([:positive])}.json"
      )

    File.write!(in_path, input)
    on_exit(fn -> File.rm(in_path) end)

    {stdout, 0} =
      System.cmd(
        "sh",
        ["-c", "python3 \"$1\" < \"$2\"", "omunculus-refresh", @refresh, in_path],
        env: [{"OMUNCULUS_CURSOR_EXCHANGE_URL", base <> "/auth/exchange_user_api_key"}],
        stderr_to_stdout: true
      )

    assert {:ok, %{"ok" => true, "output" => output, "emit" => []}} = Jason.decode(stdout)
    assert {:ok, cred} = Jason.decode(output)
    assert cred["access"] == "exchanged-access"
    assert cred["refresh"] == "refresh-token"
  end

  defp start_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    parent = self()

    pid =
      spawn_link(fn ->
        send(parent, {:ready, self()})
        accept_loop(listen)
      end)

    receive do
      {:ready, ^pid} -> {:ok, %{pid: pid, listen: listen, port: port}}
    after
      1_000 -> {:error, :timeout}
    end
  end

  defp stop_server(%{pid: pid, listen: listen}) do
    Process.exit(pid, :kill)
    :gen_tcp.close(listen)
    :ok
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        handle_http(socket)
        :gen_tcp.close(socket)
        accept_loop(listen)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_http(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, packet} ->
        request = to_string(packet)
        body = response_body(request)

        payload =
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

        :gen_tcp.send(socket, payload)

      {:error, _reason} ->
        :ok
    end
  end

  defp response_body(request) do
    cond do
      String.contains?(request, "GET /loginDeepControl") ->
        ~s({})

      String.contains?(request, "GET /auth/poll") ->
        ~s({"accessToken":"poll-access","refreshToken":"refresh-token","expiresIn":3600})

      String.contains?(request, "POST /auth/exchange_user_api_key") ->
        ~s({"accessToken":"exchanged-access","refreshToken":"refresh-token","expiresIn":3600})

      true ->
        ~s({"error":"not found"})
    end
  end
end
