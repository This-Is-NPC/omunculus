defmodule Omunculus.Model.BodyTest do
  use ExUnit.Case, async: true

  alias Omunculus.{ExecutionPolicyFixtures, Prompt}
  alias Omunculus.Model.{AnthropicMessages, Body, OpenAI, OpenAIResponses}

  test "a body key replaces the request's key of the same name, and tables merge" do
    request = %{model: "stub", stream_options: %{include_usage: true}, max_tokens: 8192}

    body = %{
      "max_tokens" => 16_000,
      "stream_options" => %{"extra" => 1},
      "reasoning" => %{"effort" => "high"}
    }

    assert Body.merge(request, body) == %{
             :model => "stub",
             "max_tokens" => 16_000,
             "stream_options" => %{:include_usage => true, "extra" => 1},
             "reasoning" => %{"effort" => "high"}
           }
  end

  test "an empty body leaves the request as it is" do
    assert Body.merge(%{model: "stub"}, %{}) == %{model: "stub"}
  end

  for {module, own} <- [
        {OpenAI, "messages"},
        {OpenAIResponses, "input"},
        {AnthropicMessages, "messages"}
      ] do
    test "#{inspect(module)} sends its body over the request it builds" do
      request =
        request(unquote(module), %{"max_tokens" => 7, "reasoning" => %{"effort" => "high"}})

      assert request["max_tokens"] == 7
      assert request["reasoning"] == %{"effort" => "high"}
      assert request["model"] == "stub"
      assert Map.has_key?(request, unquote(own))
    end
  end

  for module <- [OpenAI, OpenAIResponses, AnthropicMessages] do
    test "#{inspect(module)} offers the sandbox bridge only with code_mode" do
      named = fn request ->
        for tool <- request["tools"] || [], do: tool["name"] || get_in(tool, ["function", "name"])
      end

      refute "__omunculus_execute" in named.(request(unquote(module), %{}))

      assert "__omunculus_execute" in named.(
               request(unquote(module), %{}, nil, %{"code_mode" => true})
             )
    end
  end

  # A provider caches whole messages, so the instructions travel apart from
  # the context that changes from run to run.
  test "each adapter sends the instructions apart from the context" do
    assert %{"messages" => [system, user]} = request(OpenAI, %{})
    assert system == %{"role" => "system", "content" => "steady"}
    assert user == %{"role" => "user", "content" => "ping"}

    assert %{"instructions" => "steady", "input" => [%{"role" => "user", "content" => "ping"}]} =
             request(OpenAIResponses, %{})

    # Anthropic caches up to marked blocks: the instructions, for the next run,
    # and the last turn, for the next call of this one.
    assert %{"system" => [block], "messages" => [%{"role" => "user", "content" => [turn]}]} =
             request(AnthropicMessages, %{})

    cache = %{"cache_control" => %{"type" => "ephemeral"}}
    assert block == Map.merge(%{"type" => "text", "text" => "steady"}, cache)
    assert turn == Map.merge(%{"type" => "text", "text" => "ping"}, cache)
  end

  # A session's turns, as the tool rebuilds them, go out as each provider had them.
  test "each adapter sends a session's history as the conversation it was" do
    openai = %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => "c1",
          "type" => "function",
          "function" => %{"name" => "read", "arguments" => "{}"}
        }
      ]
    }

    assert %{"messages" => messages} =
             request(OpenAI, %{}, [
               %{"user" => "ping"},
               %{"model" => openai, "outputs" => ["body"]},
               %{"user" => "since"}
             ])

    assert messages == [
             %{"role" => "system", "content" => "steady"},
             %{"role" => "user", "content" => "ping"},
             openai,
             %{"role" => "tool", "tool_call_id" => "c1", "content" => "body"},
             %{"role" => "user", "content" => "since"}
           ]

    use = %{"type" => "tool_use", "id" => "u1", "name" => "read", "input" => %{}}

    assert %{"messages" => [first, answer, results]} =
             request(AnthropicMessages, %{}, [
               %{"user" => "ping"},
               %{"model" => %{"role" => "assistant", "content" => [use]}, "outputs" => ["body"]},
               %{"user" => "since"}
             ])

    assert first == %{"role" => "user", "content" => "ping"}
    assert answer == %{"role" => "assistant", "content" => [use]}

    # The tool results and what happened since are one user turn.
    assert [%{"type" => "tool_result", "tool_use_id" => "u1", "content" => "body"}, since] =
             results["content"]

    assert since["text"] == "since" and since["cache_control"] == %{"type" => "ephemeral"}

    item = %{"type" => "function_call", "call_id" => "f1", "name" => "read", "arguments" => "{}"}

    assert %{"input" => input} =
             request(OpenAIResponses, %{}, [
               %{"user" => "ping"},
               %{"model" => %{"output" => [item]}, "outputs" => ["body"]},
               %{"user" => "since"}
             ])

    assert input == [
             %{"role" => "user", "content" => "ping"},
             item,
             %{"type" => "function_call_output", "call_id" => "f1", "output" => "body"},
             %{"role" => "user", "content" => "since"}
           ]
  end

  defp request(module, body, history \\ nil, extra \\ %{}) do
    port = capture()

    spec =
      Map.merge(
        %{
          "url" => "http://127.0.0.1:#{port}/v1",
          "model" => "stub",
          "timeout_ms" => 5_000,
          "body" => body
        },
        extra
      )

    module.new(spec).(
      %Prompt{instructions: "steady", context: "ping", history: history},
      [],
      fn _name, _args -> {:ok, ""} end,
      fn _message -> :ok end,
      fn _text -> :ok end,
      ExecutionPolicyFixtures.policy(Application.app_dir(:omunculus, "priv"), network: "none")
    )

    assert_receive {:request, request}, 5_000
    request
  end

  test "with retries, a rate-limited request is sent again after Retry-After" do
    reply = ~s({"choices":[{"message":{"role":"assistant","content":"ok"}}]})
    limited = "HTTP/1.1 429 Too Many Requests\r\nretry-after: 0\r\ncontent-length: 0\r\n\r\n"

    answered =
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(reply)}\r\n\r\n" <>
        reply

    prompt = %Prompt{instructions: "", context: "ping"}

    policy =
      ExecutionPolicyFixtures.policy(Application.app_dir(:omunculus, "priv"), network: "none")

    spec = fn port, extra ->
      Map.merge(
        %{"url" => "http://127.0.0.1:#{port}/v1", "model" => "stub", "timeout_ms" => 5_000},
        extra
      )
    end

    call = fn spec ->
      OpenAI.new(spec).(
        prompt,
        [],
        fn _, _ -> {:ok, ""} end,
        fn _ -> :ok end,
        fn _ -> :ok end,
        policy
      )
    end

    assert {:ok, "ok"} = call.(spec.(serve([limited, answered]), %{"retries" => 2}))
    assert {:error, _limited} = call.(spec.(serve([limited, answered]), %{}))
  end

  test "arguments that are not JSON go back to the model as the call's result" do
    garbled =
      Jason.encode!(%{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "c1",
                  "type" => "function",
                  "function" => %{"name" => "read", "arguments" => "\nરસ to=functions.read"}
                }
              ]
            }
          }
        ]
      })

    answered = ~s({"choices":[{"message":{"role":"assistant","content":"ok"}}]})

    ok = fn body ->
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <>
        body
    end

    port = serve([ok.(garbled), ok.(answered)])

    policy =
      ExecutionPolicyFixtures.policy(Application.app_dir(:omunculus, "priv"), network: "none")

    spec = %{"url" => "http://127.0.0.1:#{port}/v1", "model" => "stub", "timeout_ms" => 5_000}
    test = self()

    assert {:ok, "ok"} =
             OpenAI.new(spec).(
               %Prompt{instructions: "", context: "ping"},
               [],
               fn name, _args -> send(test, {:called, name}) end,
               fn _ -> :ok end,
               fn _ -> :ok end,
               policy
             )

    refute_received {:called, _name}
  end

  # A server that answers its requests with `responses`, one each, in order.
  defp serve(responses) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      for response <- responses do
        case :gen_tcp.accept(listen, 5_000) do
          {:ok, socket} ->
            read_body(socket, "")
            :gen_tcp.send(socket, response)
            :gen_tcp.close(socket)

          {:error, :timeout} ->
            :ok
        end
      end
    end)

    port
  end

  # A server that takes one request, sends its JSON body to the test and
  # answers 500, which ends the adapter's call.
  defp capture do
    test = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 5_000)
      send(test, {:request, read_body(socket, "")})
      :gen_tcp.send(socket, "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 0\r\n\r\n")
      :gen_tcp.close(socket)
    end)

    port
  end

  defp read_body(socket, received) do
    {:ok, packet} = :gen_tcp.recv(socket, 0, 5_000)
    received = received <> packet

    with [head, body] <- String.split(received, "\r\n\r\n", parts: 2),
         [_, length] <- Regex.run(~r/content-length: (\d+)/i, head),
         true <- byte_size(body) >= String.to_integer(length) do
      Jason.decode!(body)
    else
      _incomplete -> read_body(socket, received)
    end
  end
end
