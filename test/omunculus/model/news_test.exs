defmodule Omunculus.Model.NewsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Media
  alias Omunculus.Model.{AnthropicMessages, OpenAI, OpenAIResponses}
  alias Omunculus.{HttpModelCase, Prompt}

  # A provider that asks for one tool call, then answers, keeping each request.
  defmodule Provider do
    @behaviour Plug

    def init(agent), do: agent

    def call(conn, agent) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      count = Agent.get_and_update(agent, &{length(&1), &1 ++ [request]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(reply(conn.request_path, count)))
    end

    defp reply("/chat/completions", 0) do
      call = %{
        "id" => "c1",
        "type" => "function",
        "function" => %{"name" => "echo", "arguments" => "{}"}
      }

      %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => nil, "tool_calls" => [call]}}
        ]
      }
    end

    defp reply("/chat/completions", _count),
      do: %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "done"}}]}

    defp reply("/responses", 0),
      do: %{
        "output" => [
          %{"type" => "function_call", "call_id" => "c1", "name" => "echo", "arguments" => "{}"}
        ]
      }

    defp reply("/responses", _count),
      do: %{
        "output" => [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "done"}]}
        ]
      }

    defp reply("/messages", 0),
      do: %{
        "content" => [%{"type" => "tool_use", "id" => "c1", "name" => "echo", "input" => %{}}]
      }

    defp reply("/messages", _count), do: %{"content" => [%{"type" => "text", "text" => "done"}]}
  end

  @news "A message arrived for this work while you worked:\n\nalso fix B"

  setup do
    {:ok, requests} = Agent.start_link(fn -> [] end)

    {:ok, server} =
      Bandit.start_link(plug: {Provider, requests}, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{requests: requests, url: "http://127.0.0.1:#{port}"}
  end

  # The run is told once, in the result of its call.
  defp run(module, url) do
    call = fn "echo", _args -> {:ok, Media.with_news("echoed", [@news])} end
    prompt = %Prompt{instructions: "", context: "go"}
    tools = [%{name: "echo", description: "echoes", parameters: %{}}]

    module.new(HttpModelCase.spec(url)).(
      prompt,
      tools,
      call,
      fn _reply -> :ok end,
      fn _text -> :ok end,
      HttpModelCase.policy()
    )
  end

  defp second(requests), do: requests |> Agent.get(& &1) |> Enum.at(1)

  test "chat completions: a user message follows the tool messages", %{
    requests: requests,
    url: url
  } do
    assert {:ok, "done"} = run(OpenAI, url)

    assert [
             %{"role" => "user", "content" => "go"},
             %{"role" => "assistant"},
             %{"role" => "tool", "content" => "echoed"},
             %{"role" => "user", "content" => @news}
           ] = second(requests)["messages"]
  end

  test "responses: a user item follows the outputs", %{requests: requests, url: url} do
    assert {:ok, "done"} = run(OpenAIResponses, url)

    assert [
             %{"role" => "user", "content" => "go"},
             %{"type" => "function_call"},
             %{"type" => "function_call_output", "output" => "echoed"},
             %{"role" => "user", "content" => @news}
           ] = second(requests)["input"]
  end

  test "messages: a text block follows the tool results", %{requests: requests, url: url} do
    assert {:ok, "done"} = run(AnthropicMessages, url)

    assert [
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{
               "role" => "user",
               "content" => [%{"type" => "tool_result"}, %{"type" => "text", "text" => @news}]
             }
           ] = second(requests)["messages"]
  end
end
