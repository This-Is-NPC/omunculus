defmodule Omunculus.Chat.CompletionsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Chat.Completions

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  test "posts non-streaming chat completions and unwraps the message", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      refute payload["stream"]
      assert payload["model"] == "fake-model"
      assert hd(payload["tools"])["type"] == "function"

      [auth] = Plug.Conn.get_req_header(conn, "authorization")
      assert auth == "Bearer sk-test"

      Plug.Conn.put_resp_content_type(conn, "application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "chatcmpl-1",
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => "hi",
                "tool_calls" => []
              }
            }
          ],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        })
      )
    end)

    chat =
      Completions.new(
        base_url: "http://127.0.0.1:#{bypass.port}/v1",
        model: "fake-model",
        auth: {Omunculus.Auth.ApiKey, %{type: "api_key", key: "sk-test"}}
      )

    tools = Omunculus.Tools.schemas(["read"])

    assert {:ok, reply} =
             Completions.complete(chat, [%{"role" => "user", "content" => "hi"}], tools)

    assert reply.content == "hi"
    assert reply.tool_calls == nil
    assert reply.usage["total_tokens"] == 2
  end

  test "configured transport timeout and unbounded generation" do
    # A timed-out client intentionally closes its socket. A raw fixture avoids
    # treating that expected disconnect as a failed Bypass expectation.
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    body = Jason.encode!(%{choices: [%{message: %{content: "done"}}]})

    server =
      Task.async(fn ->
        for _ <- 1..2 do
          {:ok, socket} = :gen_tcp.accept(listener, 2000)
          :gen_tcp.recv(socket, 0, 2000)
          Process.sleep(100)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
              body
          )

          :gen_tcp.close(socket)
        end
      end)

    config = %{
      api: "openai-completions",
      auth: "none",
      base_url: "http://127.0.0.1:#{port}/v1",
      model: "test",
      api_key: nil,
      timeout_ms: 30
    }

    {:ok, limited} = Omunculus.Runner.build_chat(config, %{}, %{})
    assert {:error, %Req.TransportError{reason: :timeout}} = Completions.complete(limited, [], [])
    {:ok, unbounded} = Omunculus.Runner.build_chat(%{config | timeout_ms: "infinity"}, %{}, %{})
    assert unbounded.timeout_ms == :infinity
    assert {:ok, %{content: "done"}} = Completions.complete(unbounded, [], [])
    Task.await(server)
  end

  test "unknown api types are refused by Chat.resolve" do
    assert {:error, {:unsupported_api, "openai-codex-responses"}} =
             Omunculus.Chat.resolve("openai-codex-responses")

    assert {:error, {:unsupported_auth, "oauth"}} = Omunculus.Auth.resolve("oauth")
  end
end
