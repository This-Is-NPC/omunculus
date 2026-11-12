defmodule Omunculus.Model.MediaWireTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Fixtures, HttpModelCase}
  alias Omunculus.Model.{AnthropicMessages, OpenAI, OpenAIResponses}

  # Per adapter: a tool call, the reply to its result, and the provider's
  # own tool-call and final reply.
  @wires [
    {AnthropicMessages,
     %{"content" => [%{"type" => "tool_use", "id" => "c1", "name" => "counter", "input" => %{}}]},
     %{"content" => [%{"type" => "text", "text" => "ok"}]}},
    {OpenAI,
     %{
       "choices" => [
         %{
           "message" => %{
             "role" => "assistant",
             "content" => nil,
             "tool_calls" => [
               %{
                 "id" => "c1",
                 "type" => "function",
                 "function" => %{"name" => "counter", "arguments" => "{}"}
               }
             ]
           }
         }
       ]
     }, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}},
    {OpenAIResponses,
     %{
       "output" => [
         %{"type" => "function_call", "call_id" => "c1", "name" => "counter", "arguments" => "{}"}
       ]
     },
     %{
       "output" => [
         %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
       ]
     }}
  ]

  # Serves each reply to one request and sends the test each request's body.
  defp serve(replies) do
    test = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    pid =
      spawn_link(fn ->
        for reply <- replies do
          {:ok, socket} = :gen_tcp.accept(listen, 30_000)
          send(test, {:request, read_body(socket, "")})
          body = Jason.encode!(reply)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
          )

          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp read_body(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, head)
        need = String.to_integer(length) - byte_size(body)
        if need > 0, do: body <> receive_exactly(socket, need), else: body

      [_incomplete] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 30_000)
        read_body(socket, buffer <> more)
    end
  end

  defp receive_exactly(socket, need) do
    {:ok, data} = :gen_tcp.recv(socket, need, 30_000)
    data
  end

  defp shown(ctx, name, type, bytes) do
    file = Path.join(ctx.dir, name)
    File.write!(file, bytes)
    %{text: "#{name} read", media: [%{"media_type" => type, "name" => name, "file" => file}]}
  end

  defp run(module, spec, tool, replies) do
    url = serve(replies)
    call = fn "counter", %{} -> {:ok, tool} end

    {:ok, "ok"} =
      module.new(Map.merge(HttpModelCase.spec(url), spec)).(
        HttpModelCase.assembled(),
        HttpModelCase.tools(),
        call,
        fn _message -> :ok end,
        fn _text -> :ok end,
        HttpModelCase.policy()
      )

    assert_receive {:request, _first}, 5_000
    assert_receive {:request, second}, 5_000
    Jason.decode!(second)
  end

  setup do
    %{dir: Fixtures.tmp_dir()}
  end

  for {module, call, final} <- @wires do
    describe "#{inspect(module)}" do
      test "sends an image a tool shows as the provider's image content", ctx do
        wire =
          run(
            unquote(module),
            %{},
            shown(ctx, "page.png", "image/png", Fixtures.png()),
            [unquote(Macro.escape(call)), unquote(Macro.escape(final))]
          )

        encoded = Base.encode64(Fixtures.png())
        text = Jason.encode!(wire)
        assert text =~ encoded

        case unquote(module) do
          AnthropicMessages ->
            [_user, _assistant, %{"content" => [%{"content" => [_text, image]}]}] =
              wire["messages"]

            assert image == %{
                     "type" => "image",
                     "source" => %{
                       "type" => "base64",
                       "media_type" => "image/png",
                       "data" => encoded
                     }
                   }

          OpenAI ->
            assert %{"role" => "user", "content" => [_text, image]} = List.last(wire["messages"])

            assert image == %{
                     "type" => "image_url",
                     "image_url" => %{"url" => "data:image/png;base64," <> encoded}
                   }

          OpenAIResponses ->
            assert %{"output" => [_text, image]} = List.last(wire["input"])

            assert image == %{
                     "type" => "input_image",
                     "image_url" => "data:image/png;base64," <> encoded
                   }
        end
      end

      test "sends a PDF as the provider's document content", ctx do
        pdf = "%PDF-1.4 fixture"

        wire =
          run(
            unquote(module),
            %{},
            shown(ctx, "spec.pdf", "application/pdf", pdf),
            [
              unquote(Macro.escape(call)),
              unquote(Macro.escape(final))
            ]
          )

        encoded = Base.encode64(pdf)

        part =
          case unquote(module) do
            AnthropicMessages ->
              hd(wire["messages"] |> List.last() |> Map.fetch!("content"))
              |> Map.fetch!("content")
              |> List.last()

            OpenAI ->
              wire["messages"] |> List.last() |> Map.fetch!("content") |> List.last()

            OpenAIResponses ->
              wire["input"] |> List.last() |> Map.fetch!("output") |> List.last()
          end

        case unquote(module) do
          AnthropicMessages ->
            assert part["type"] == "document"
            assert part["source"]["data"] == encoded

          OpenAI ->
            assert part == %{
                     "type" => "file",
                     "file" => %{
                       "filename" => "spec.pdf",
                       "file_data" => "data:application/pdf;base64," <> encoded
                     }
                   }

          OpenAIResponses ->
            assert part == %{
                     "type" => "input_file",
                     "filename" => "spec.pdf",
                     "file_data" => "data:application/pdf;base64," <> encoded
                   }
        end
      end

      test "says in the result what a model that takes no media is not sent", ctx do
        wire =
          run(
            unquote(module),
            %{"media_types" => []},
            shown(ctx, "page.png", "image/png", Fixtures.png()),
            [unquote(Macro.escape(call)), unquote(Macro.escape(final))]
          )

        text = Jason.encode!(wire)
        refute text =~ Base.encode64(Fixtures.png())
        assert text =~ "page.png is not shown: this model takes no media, not image/png"
      end
    end
  end
end
