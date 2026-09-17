defmodule Omunculus.Tools.CursorLoginTest do
  use ExUnit.Case, async: true

  @login Application.app_dir(:omunculus, "priv/tools/cursor_login/run")
  @refresh Application.app_dir(:omunculus, "priv/tools/cursor_refresh/run")

  test "cursor_login polls a fake server and prints a credential" do
    {:ok, server} = start_server()
    on_exit(fn -> stop_server(server) end)
    base = "http://127.0.0.1:#{server.port}"

    {stdout, 0} =
      python(
        @login,
        "",
        [
          {"OMUNCULUS_CURSOR_LOGIN_URL", base <> "/loginDeepControl"},
          {"OMUNCULUS_CURSOR_POLL_URL", base <> "/auth/poll"},
          {"OMUNCULUS_CURSOR_EXCHANGE_URL", base <> "/auth/exchange_user_api_key"},
          {"OMUNCULUS_CURSOR_NO_BROWSER", "1"},
          {"OMUNCULUS_CURSOR_POLL_SECONDS", "5"}
        ]
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

    {stdout, 0} =
      python(@refresh, input, [
        {"OMUNCULUS_CURSOR_EXCHANGE_URL", base <> "/auth/exchange_user_api_key"}
      ])

    assert {:ok, %{"ok" => true, "output" => output, "emit" => []}} = Jason.decode(stdout)
    assert {:ok, cred} = Jason.decode(output)
    assert cred["access"] == "exchanged-access"
    assert cred["refresh"] == "refresh-token"
  end

  defp python(script, stdin, extra_env) do
    env = [
      {"no_proxy", "*"},
      {"NO_PROXY", "*"},
      {"http_proxy", ""},
      {"https_proxy", ""},
      {"HTTP_PROXY", ""},
      {"HTTPS_PROXY", ""}
      | extra_env
    ]

    path =
      Path.join(
        System.tmp_dir!(),
        "omunculus-cursor-#{System.unique_integer([:positive])}.in"
      )

    File.write!(path, stdin)
    on_exit(fn -> File.rm(path) end)

    System.cmd(
      "sh",
      ["-c", "exec python3 \"$1\" < \"$2\"", "omunculus-python", script, path],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp start_server do
    {:ok, listen} =
      :gen_tcp.listen(
        0,
        [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}, backlog: 16]
      )

    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept_loop(listen) end)
    {:ok, %{pid: pid, listen: listen, port: port}}
  end

  defp stop_server(%{pid: pid, listen: listen}) do
    Process.exit(pid, :kill)
    :gen_tcp.close(listen)
    :ok
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen, 10_000) do
      {:ok, socket} ->
        handle_http(socket)
        :gen_tcp.close(socket)
        accept_loop(listen)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_http(socket) do
    case recv_headers(socket, "") do
      {:ok, request} ->
        _ = drain_body(socket, request)
        body = response_body(request)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
        )

      {:error, _reason} ->
        :ok
    end
  end

  defp drain_body(socket, request) do
    case Regex.run(~r/content-length:\s*(\d+)/i, request) do
      [_, digits] -> recv_n(socket, String.to_integer(digits))
      nil -> :ok
    end
  end

  defp recv_n(_socket, 0), do: :ok

  defp recv_n(socket, n) do
    case :gen_tcp.recv(socket, n, 2_000) do
      {:ok, _data} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 1, 2_000) do
        {:ok, byte} -> recv_headers(socket, acc <> byte)
        {:error, reason} -> {:error, reason}
      end
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
