defmodule Omunculus.Model.AnthropicMessages do
  @moduledoc """
  Factory for an Anthropic Messages model of the model contract:
  `new/1` takes the `[models.<name>]` spec (`url`, `model`, `timeout_ms`,
  optional `temperature`, `headers`, `body`, `credential`) and returns a 6-arity
  `(prompt, tools, call, record, delta, execution)` fun. Posts the prompt's
  instructions as `system` and its context as the first user turn, or,
  continuing a session, the session's turns as they were and what
  happened since, to
  `<url>/messages` with tools as Anthropic `input_schema` items, runs each
  `tool_use` through `call.(name, args)`, appends a `tool_result` user
  turn, and loops until a reply has none. Two cache breakpoints mark each
  request: the end of the instructions, which the next run of the agent
  reuses, and the end of the last turn, which the next call of the run
  reuses. Each reply is recorded with its `usage`.
  With `code_mode`, `__omunculus_execute` is the same sandbox bridge as
  `Model.OpenAI`.
  With `stream = true` the reply is read as server-sent events and put
  back together from its content blocks, each `text_delta` going to
  `delta`. The `url` is always the spec's; nothing in this module names a
  host.
  """

  alias Omunculus.{Maps, Media}
  alias Omunculus.Model.{Body, EventStream, HTTP}
  alias Omunculus.Prompt

  @spec new(map) ::
          (Prompt.t(),
           [map],
           (String.t(), map -> {:ok, String.t()} | {:error, term}),
           (map -> :ok | {:error, term}),
           (String.t() -> :ok),
           Omunculus.Execution.Policy.t() ->
             {:ok, String.t()} | {:error, term})
  def new(spec) when is_map(spec) do
    client = HTTP.client(spec, "/messages", request_headers(spec))

    fn %Prompt{} = prompt, tools, call, record, delta, execution ->
      loop(
        Map.put(client, :delta, delta),
        system(prompt.instructions),
        HTTP.tools(client, tools, &anthropic_tool/1),
        conversation(prompt),
        call,
        record,
        tools,
        execution
      )
    end
  end

  # Anthropic caches only up to a marked block: the instructions end in one.
  @cache %{type: "ephemeral"}

  defp system(""), do: nil

  defp system(instructions),
    do: [%{type: "text", text: instructions, cache_control: @cache}]

  defp request_headers(spec) do
    base = [
      {"content-type", "application/json"},
      {"anthropic-version", "2023-06-01"}
    ]

    cred =
      case Map.get(spec, "credential") do
        %{"access" => access} when is_binary(access) and access != "" ->
          [{"x-api-key", access}, {"authorization", "Bearer " <> access}]

        %{access: access} when is_binary(access) and access != "" ->
          [{"x-api-key", access}, {"authorization", "Bearer " <> access}]

        _absent ->
          []
      end

    base ++ cred ++ HTTP.headers_list(Map.get(spec, "headers"))
  end

  defp anthropic_tool(%{name: name, description: description, parameters: parameters}) do
    %{
      name: name,
      description: description,
      input_schema: HTTP.parameters_schema(parameters)
    }
  end

  defp loop(client, system, tools, messages, call, record, catalog, execution) do
    with {:ok, message} <- post(client, request_body(client, system, tools, messages)),
         :ok <- record.(recorded(client, message)) do
      case tool_uses(message) do
        [] ->
          {:ok, output_text(message)}

        uses ->
          {results, news} =
            uses
            |> Enum.map(&run_tool_use(&1, call, catalog, execution, client.media_types))
            |> Enum.unzip()

          loop(
            client,
            system,
            tools,
            messages ++
              [
                assistant_turn(message),
                %{role: "user", content: results ++ text_blocks(List.flatten(news))}
              ],
            call,
            record,
            catalog,
            execution
          )
      end
    end
  end

  defp request_body(client, system, tools, messages) do
    %{
      model: client.model,
      messages: mark_last(messages),
      tools: tools
    }
    |> Maps.maybe_put(:system, system)
    |> Maps.maybe_put(:temperature, client.temperature)
    |> Maps.maybe_put(:stream, client.stream || nil)
    |> Body.merge(client.body)
  end

  # A run continuing its session sends the session as it was, then what
  # happened since; turns of the same role are one.
  defp conversation(%Prompt{history: nil, context: context}),
    do: [%{role: "user", content: context}]

  defp conversation(%Prompt{history: history}) do
    history
    |> Enum.flat_map(&turn/1)
    |> Enum.chunk_by(& &1.role)
    |> Enum.map(fn
      [single] -> single
      [first | _] = same -> %{role: first.role, content: Enum.flat_map(same, &blocks(&1.content))}
    end)
  end

  defp turn(%{"user" => text}), do: [%{role: "user", content: text}]

  defp turn(%{"model" => reply, "outputs" => outputs} = item) do
    uses = for %{"type" => "tool_use"} = use <- reply["content"], do: use
    results = Enum.zip_with(uses, outputs, fn use, out -> tool_result(use["id"], {:ok, out}) end)
    answer = %{role: "assistant", content: reply["content"]}

    if results == [],
      do: [answer],
      else: [answer, %{role: "user", content: results ++ text_blocks(item["news"])}]
  end

  defp text_blocks(texts), do: Enum.map(texts || [], &%{type: "text", text: &1})

  defp blocks(text) when is_binary(text), do: [%{type: "text", text: text}]
  defp blocks(blocks), do: blocks

  # The last block of the last turn ends the prefix the next call shares.
  defp mark_last(messages) do
    {last, earlier} = List.pop_at(messages, -1)

    blocks =
      case last.content do
        text when is_binary(text) -> [%{type: "text", text: text}]
        blocks -> blocks
      end

    {block, before} = List.pop_at(blocks, -1)
    earlier ++ [%{last | content: before ++ [Map.put(block, :cache_control, @cache)]}]
  end

  defp post(%{stream: true} = client, body) do
    reply = %{message: nil, blocks: %{}, json: %{}}

    case EventStream.post(client, body, reply, &event(&1, &2, client)) do
      {:ok, %{message: message} = reply} when is_map(message) ->
        extract_message(Map.put(message, "content", streamed_content(reply)))

      {:ok, _incomplete} ->
        {:error, {:anthropic, {:invalid_response, :incomplete}}}

      {:error, reason} ->
        {:error, {:anthropic, reason}}
    end
  end

  defp post(client, body) do
    case HTTP.post(client, body) do
      {:ok, response_body} -> extract_message(response_body)
      {:error, reason} -> {:error, {:anthropic, reason}}
    end
  end

  defp extract_message(%{"content" => content} = message) when is_list(content),
    do: {:ok, message}

  defp extract_message(body), do: {:error, {:anthropic, {:invalid_response, body}}}

  defp event(%{"type" => "message_start", "message" => message}, reply, _client),
    do: %{reply | message: message}

  defp event(%{"type" => "content_block_start", "index" => index} = data, reply, _client),
    do: %{reply | blocks: Map.put(reply.blocks, index, data["content_block"])}

  defp event(
         %{"type" => "content_block_delta", "index" => index, "delta" => delta},
         reply,
         client
       ) do
    case delta do
      %{"type" => "text_delta", "text" => text} ->
        :ok = client.delta.(text)

        %{
          reply
          | blocks:
              Map.update!(
                reply.blocks,
                index,
                &Map.update(&1, "text", text, fn prior -> prior <> text end)
              )
        }

      %{"type" => "input_json_delta", "partial_json" => json} ->
        %{reply | json: Map.update(reply.json, index, json, &(&1 <> json))}

      # A thinking block goes back as it came: its text, which may be left
      # out, and the signature that vouches for it.
      %{"type" => "thinking_delta", "thinking" => thinking} ->
        %{
          reply
          | blocks:
              Map.update!(
                reply.blocks,
                index,
                &Map.update(&1, "thinking", thinking, fn prior -> prior <> thinking end)
              )
        }

      %{"type" => "signature_delta", "signature" => signature} ->
        %{reply | blocks: Map.update!(reply.blocks, index, &Map.put(&1, "signature", signature))}

      _other ->
        reply
    end
  end

  # The delta carries the stop reason and the output's usage, which
  # completes the usage message_start began.
  defp event(
         %{"type" => "message_delta", "delta" => delta} = data,
         %{message: message} = reply,
         _
       )
       when is_map(message) do
    usage = Map.merge(message["usage"] || %{}, data["usage"] || %{})
    %{reply | message: message |> Map.merge(delta) |> Map.put("usage", usage)}
  end

  defp event(_other, reply, _client), do: reply

  defp streamed_content(reply) do
    reply.blocks
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {index, block} ->
      case Map.fetch(reply.json, index) do
        {:ok, ""} -> Map.put(block, "input", %{})
        {:ok, json} -> Map.put(block, "input", Jason.decode!(json))
        :error -> block
      end
    end)
  end

  # The reply as recorded, with the model that answered, or the one the
  # request named when the provider does not say.
  defp recorded(client, message) do
    message
    |> Map.take(["role", "content", "stop_reason", "usage"])
    |> Map.put("model", message["model"] || client.model)
  end

  defp assistant_turn(message) do
    %{role: "assistant", content: Map.get(message, "content", [])}
  end

  defp tool_uses(%{"content" => content}) when is_list(content) do
    Enum.filter(content, fn
      %{"type" => "tool_use"} -> true
      _ -> false
    end)
  end

  defp tool_uses(_message), do: []

  defp output_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(&text_chunks/1)
    |> Enum.join()
  end

  defp output_text(_message), do: ""

  defp text_chunks(%{"type" => "text", "text" => text}) when is_binary(text), do: [text]
  defp text_chunks(%{"text" => text}) when is_binary(text), do: [text]
  defp text_chunks(_item), do: []

  defp run_tool_use(
         %{"id" => id, "name" => name, "input" => input},
         call,
         catalog,
         execution,
         media_types
       ) do
    result = HTTP.run(name, input, call, catalog, execution)
    {tool_result(id, result, media_types), news(result)}
  end

  defp news({:ok, result}), do: Media.news(result)
  defp news({:error, _reason}), do: []

  # A result that shows media is a list of blocks: its text, then the
  # images and documents.
  defp tool_result(id, result, media_types \\ nil)

  defp tool_result(id, {:ok, result}, media_types) do
    {text, media} = Media.render(result, media_types)
    %{type: "tool_result", tool_use_id: id, content: tool_content(text, media)}
  end

  defp tool_result(id, {:error, reason}, _media_types),
    do: %{type: "tool_result", tool_use_id: id, content: Omunculus.Tools.Out.failure(reason)}

  defp tool_content(text, []), do: text

  defp tool_content(text, media) do
    texts = if text == "", do: [], else: [%{type: "text", text: text}]
    texts ++ Enum.map(media, &media_block/1)
  end

  defp media_block(%{"media_type" => "application/pdf", "data" => data}),
    do: %{type: "document", source: %{type: "base64", media_type: "application/pdf", data: data}}

  defp media_block(%{"media_type" => type, "data" => data}),
    do: %{type: "image", source: %{type: "base64", media_type: type, data: data}}
end
