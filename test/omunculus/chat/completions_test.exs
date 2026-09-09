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

  test "configured transport timeout and unbounded generation", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      Process.sleep(80)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{choices: [%{message: %{content: "done"}}]}))
    end)

    config = %{
      api: "openai-completions",
      auth: "none",
      base_url: "http://127.0.0.1:#{bypass.port}/v1",
      model: "test",
      api_key: nil,
      timeout_ms: 1
    }

    {:ok, limited} = Omunculus.Runner.build_chat(config, %{}, %{})
    assert {:error, %Req.TransportError{reason: :timeout}} = Completions.complete(limited, [], [])
    {:ok, unbounded} = Omunculus.Runner.build_chat(%{config | timeout_ms: "infinity"}, %{}, %{})
    assert unbounded.timeout_ms == :infinity
    assert {:ok, %{content: "done"}} = Completions.complete(unbounded, [], [])
  end

  test "unknown api types are refused by Chat.resolve" do
    assert {:error, {:unsupported_api, "openai-codex-responses"}} =
             Omunculus.Chat.resolve("openai-codex-responses")

    assert {:error, {:unsupported_auth, "oauth"}} = Omunculus.Auth.resolve("oauth")
  end
end
