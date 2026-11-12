defmodule Omunculus.Model.OpenAI do
  @moduledoc """
  Factory for an OpenAI-compatible model of the model contract:
  `new/1` takes the `[models.<name>]` spec (`url`, `model`, `timeout_ms`,
  optional `temperature`, `headers`, `body`, `prompt_cache_key`, `credential`) and
  returns a 6-arity
  `(prompt, tools, call, record, delta, execution)` fun. Declares each of
  `tools` (the run's effective tools, as `%{name, description,
  parameters}`) as a function with its real `parameters` schema — an
  empty schema becomes `%{type: "object", properties: %{}}` so servers
  accept it — posts the prompt's instructions as a `system` message and
  its context as the user turn, or, continuing a session, the session's
  messages as they were and what happened since, to
  `<url>/chat/completions`, and for every `tool_calls` entry in the
  reply runs `call.(name, args)` and feeds the output back as a `tool`
  message, looping until a reply carries no tool call. Every reply is
  recorded before dispatch, with the reply's `usage` when the server
  sends one; the next request carries the reply without it.
  With `code_mode`, the model is also offered `__omunculus_execute`, which
  runs JavaScript in the sandbox through the same authorized call
  callback as native tool calls. With `stream = true` the
  reply is read as server-sent events, its text passed to `delta` as it
  arrives, and `stream_options.include_usage` asks for the `usage` chunk.
  """

  alias Omunculus.{Maps, Media}
  alias Omunculus.Tools.Out
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
    client = HTTP.client(spec, "/chat/completions", request_headers(spec))

    fn prompt, tools, call, record, delta, execution ->
      loop(
        Map.put(client, :delta, delta),
        HTTP.tools(client, tools, &function_tool/1),
        messages(prompt),
        call,
        record,
        tools,
        execution
      )
    end
  end

  @doc false
  def request_headers(spec) do
    explicit = HTTP.headers_list(Map.get(spec, "headers"))

    case Map.get(spec, "credential") do
      %{"access" => access} when is_binary(access) and access != "" ->
        [{"authorization", "Bearer " <> access} | explicit]

      %{access: access} when is_binary(access) and access != "" ->
        [{"authorization", "Bearer " <> access} | explicit]

      _absent ->
        explicit
    end
  end

  # The instructions are a message of their own: a server caches whole
  # messages, so the next run's request reuses them though its context differs.
  defp messages(%Prompt{instructions: instructions} = prompt),
    do: system(instructions) ++ conversation(prompt)

  defp system(""), do: []
  defp system(instructions), do: [%{role: "system", content: instructions}]

  # A run continuing its session sends the session as it was: the same
  # messages the provider has in its cache, then what happened since.
  defp conversation(%Prompt{history: nil, context: context}),
    do: [%{role: "user", content: context}]

  defp conversation(%Prompt{history: history}), do: Enum.flat_map(history, &turn/1)

  defp turn(%{"user" => text}), do: [%{role: "user", content: text}]

  defp turn(%{"model" => reply, "outputs" => outputs} = item) do
    calls = Enum.zip(reply["tool_calls"] || [], outputs)
    [strip_message(reply) | Enum.map(calls, &tool_message/1)] ++ user_messages(item["news"])
  end

  defp user_messages(news), do: Enum.map(news || [], &%{role: "user", content: &1})

  defp tool_message({%{"id" => id}, output}),
    do: %{role: "tool", tool_call_id: id, content: output}

  defp function_tool(%{name: name, description: description, parameters: parameters}) do
    %{
      type: "function",
      function: %{
        name: name,
        description: description,
        parameters: HTTP.parameters_schema(parameters)
      }
    }
  end

  defp loop(client, tools, messages, call, record, catalog, execution) do
    with {:ok, message} <- post(client, request_body(client, tools, messages)),
         :ok <- record.(recorded(client, message)) do
      case message do
        %{"tool_calls" => [_ | _] = tool_calls} ->
          {tool_messages, shown} =
            tool_calls
            |> Enum.map(&run_tool_call(&1, call, catalog, execution, client.media_types))
            |> Enum.unzip()

          {media, news} = Enum.unzip(shown)

          loop(
            client,
            tools,
            messages ++
              [strip_message(message) | tool_messages] ++
              media_message(media) ++ user_messages(List.flatten(news)),
            call,
            record,
            catalog,
            execution
          )

        _final ->
          {:ok, message["content"] || ""}
      end
    end
  end

  # The reply as recorded: with its usage and the model that answered, the
  # one the request named when the provider does not say.
  defp recorded(client, message) do
    message
    |> strip_message()
    |> Maps.maybe_put("usage", message["usage"])
    |> Map.put("model", message["model"] || client.model)
  end

  defp request_body(client, tools, messages) do
    %{model: client.model, messages: messages, tools: tools}
    |> Maps.maybe_put(:temperature, client.temperature)
    |> Maps.maybe_put(:prompt_cache_key, client.prompt_cache_key)
    |> Maps.maybe_put(:stream, client.stream || nil)
    |> Maps.maybe_put(:stream_options, if(client.stream, do: %{include_usage: true}))
    |> Body.merge(client.body)
  end

  defp post(%{stream: true} = client, body) do
    reply = %{content: nil, tool_calls: %{}, usage: nil, model: nil}

    case EventStream.post(client, body, reply, &chunk(&1, &2, client)) do
      {:ok, reply} -> {:ok, streamed_message(reply)}
      {:error, reason} -> {:error, {:openai, reason}}
    end
  end

  defp post(client, body) do
    case HTTP.post(client, body) do
      {:ok, response_body} -> extract_message(response_body)
      {:error, reason} -> {:error, {:openai, reason}}
    end
  end

  defp extract_message(%{"choices" => [%{"message" => message} | _]} = body),
    do:
      {:ok,
       message |> Maps.maybe_put("usage", body["usage"]) |> Maps.maybe_put("model", body["model"])}

  defp extract_message(body), do: {:error, {:openai, {:invalid_response, body}}}

  defp chunk(%{"choices" => [%{"delta" => delta} | _]} = data, reply, client) do
    reply
    |> chunk_model(data["model"])
    |> chunk_usage(data["usage"])
    |> chunk_content(delta["content"], client)
    |> chunk_tool_calls(delta["tool_calls"])
  end

  defp chunk(data, reply, _client),
    do: reply |> chunk_model(data["model"]) |> chunk_usage(data["usage"])

  defp chunk_model(reply, nil), do: reply
  defp chunk_model(reply, model), do: %{reply | model: model}

  defp chunk_usage(reply, nil), do: reply
  defp chunk_usage(reply, usage), do: %{reply | usage: usage}

  defp chunk_content(reply, text, client) when is_binary(text) and text != "" do
    :ok = client.delta.(text)
    %{reply | content: (reply.content || "") <> text}
  end

  defp chunk_content(reply, _text, _client), do: reply

  defp chunk_tool_calls(reply, [_ | _] = calls) do
    Enum.reduce(calls, reply, fn %{"index" => index} = part, reply ->
      current =
        Map.get(reply.tool_calls, index, %{
          "id" => nil,
          "type" => "function",
          "function" => %{"name" => "", "arguments" => ""}
        })

      function = Map.get(part, "function", %{})

      updated =
        current
        |> Map.put("id", part["id"] || current["id"])
        |> update_in(["function", "name"], &(&1 <> (function["name"] || "")))
        |> update_in(["function", "arguments"], &(&1 <> (function["arguments"] || "")))

      %{reply | tool_calls: Map.put(reply.tool_calls, index, updated)}
    end)
  end

  defp chunk_tool_calls(reply, _calls), do: reply

  defp streamed_message(%{content: content, tool_calls: calls, usage: usage, model: model}) do
    message =
      %{"role" => "assistant", "content" => content}
      |> Maps.maybe_put("usage", usage)
      |> Maps.maybe_put("model", model)

    case calls |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) do
      [] -> message
      tool_calls -> Map.put(message, "tool_calls", tool_calls)
    end
  end

  # A tool message holds text alone: the media a call shows follows the
  # call's messages as one user message, then the messages the run was told.
  defp run_tool_call(
         %{"id" => id, "function" => %{"name" => name, "arguments" => arguments}},
         call,
         catalog,
         execution,
         media_types
       ) do
    case HTTP.run(name, arguments, call, catalog, execution) do
      {:ok, result} ->
        {text, media} = Media.render(result, media_types)
        {%{role: "tool", tool_call_id: id, content: text}, {media, Media.news(result)}}

      {:error, reason} ->
        {%{role: "tool", tool_call_id: id, content: Omunculus.Tools.Out.failure(reason)},
         {[], []}}
    end
  end

  defp media_message(media) do
    case List.flatten(media) do
      [] ->
        []

      parts ->
        [
          %{
            role: "user",
            content: [%{type: "text", text: Out.media_follows()} | Enum.map(parts, &media_part/1)]
          }
        ]
    end
  end

  defp media_part(%{"media_type" => "application/pdf", "name" => name} = part),
    do: %{type: "file", file: %{filename: name, file_data: Media.data_url(part)}}

  defp media_part(part),
    do: %{type: "image_url", image_url: %{url: Media.data_url(part)}}

  defp strip_message(message), do: Map.take(message, ["role", "content", "tool_calls"])
end
