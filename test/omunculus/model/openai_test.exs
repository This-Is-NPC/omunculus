defmodule Omunculus.Model.OpenAITest do
  use Omunculus.HttpModelCase,
    module: Omunculus.Model.OpenAI,
    error: :openai,
    prompt_cache_key: true

  alias Omunculus.Model.OpenAI

  for javascript <- [false, true], stream <- [false, true] do
    test "records all model turns and executes tools (JavaScript: #{javascript}, stream: #{stream})",
         %{stub: stub, base_url: base_url} do
      :ok = OpenAIStub.configure(stub, tool_rounds: 1, javascript: unquote(javascript))
      events = run_counter("openai-completions", base_url, unquote(stream))

      assert Enum.map(events, & &1.type) == ~w(start-run tool model tool model end-run)
      [first, last] = replies = Enum.filter(events, &(&1.type == "model"))
      assert Jason.decode!(first.body)["tool_calls"] != []
      assert Jason.decode!(last.body)["content"] == "benchmark complete"

      assert Enum.all?(replies, fn reply ->
               Jason.decode!(reply.body)["usage"]["prompt_tokens_details"]["cached_tokens"] == 2
             end)
    end
  end

  @tag cargo: false
  test "sends Bearer from credential" do
    {:ok, server} = start_header_server()

    model =
      OpenAI.new(%{
        "url" => "http://127.0.0.1:#{server.port}/v1",
        "model" => "stub",
        "timeout_ms" => 120_000,
        "credential" => %{"access" => "secret-token"}
      })

    {_agent, call} = recorder()

    assert {:ok, text} =
             model.("ping", [], call, fn _message -> :ok end, fn _text -> :ok end, policy())

    assert text =~ "ok"
    assert_receive {:auth_header, "Bearer secret-token"}, 5_000
    Process.exit(server.pid, :kill)
  end

  defp start_header_server do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, port} = :inet.port(listen)
        send(parent, {:ready, port})

        {:ok, socket} = :gen_tcp.accept(listen, 30_000)
        {:ok, packet} = :gen_tcp.recv(socket, 0, 30_000)
        packet = to_string(packet)

        auth =
          packet
          |> String.split("\r\n")
          |> Enum.find_value("", fn line ->
            case String.split(line, ": ", parts: 2) do
              [key, value] ->
                if String.downcase(key) == "authorization", do: value, else: false

              _ ->
                false
            end
          end)

        send(parent, {:auth_header, auth})

        body =
          Jason.encode!(%{
            "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
          })

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
        )

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)

    receive do
      {:ready, port} -> {:ok, %{pid: pid, port: port}}
    after
      5_000 -> flunk("header server did not start")
    end
  end

  @tag :local_model
  test "talks to a real local OpenAI-compatible server" do
    base_url = System.fetch_env!("OMUNCULUS_OPENAI_URL")
    model_name = System.fetch_env!("OMUNCULUS_OPENAI_MODEL")
    model = OpenAI.new(spec(base_url, model_name))
    {_agent, call} = recorder()

    assert {:ok, text} =
             model.(
               "Reply only: pong",
               [],
               call,
               fn _message -> :ok end,
               fn _text -> :ok end,
               policy()
             )

    assert text =~ "pong"
  end
end
