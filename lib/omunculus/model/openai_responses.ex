defmodule Omunculus.Model.OpenAIResponses do
  @moduledoc """
  Factory for an OpenAI Responses model of the model contract:
  `new/1` takes the `[models.<name>]` spec (`url`, `model`, `timeout_ms`,
  optional `temperature`, `headers`, `body`, `prompt_cache_key`, `credential`) and
  returns a 6-arity
  `(prompt, tools, call, record, delta, execution)` fun. Posts the prompt's
  instructions as `instructions` and its context as `input`, or, continuing
  a session, the session's items as they were and what happened since, to
  `<url>/responses` with tools as `function` items, runs
  each `function_call` through `call.(name, args)`, appends
  `function_call_output`, and loops until a reply has none. Each reply is
  recorded as its `output` and, when the server sends one, its `usage`.
  With `code_mode`, `__omunculus_execute` is the same sandbox bridge as
  `Model.OpenAI`.
  With `stream = true` the reply is read as server-sent events: each
  `response.output_text.delta` goes to `delta`, and `response.completed`
  carries the response. The `url` is always the spec's; nothing in this
  module names a host.
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
    client = HTTP.client(spec, "/responses", Omunculus.Model.OpenAI.request_headers(spec))

    fn %Prompt{} = prompt, tools, call, record, delta, execution ->
      loop(
        Map.merge(client, %{delta: delta, instructions: prompt.instructions}),
        HTTP.tools(client, tools, &function_tool/1),
        input(prompt),
        call,
        record,
        tools,
        execution
      )
    end
  end

  # A run continuing its session sends the session as it was, then what
  # happened since.
  defp input(%Prompt{history: nil, context: context}), do: [%{role: "user", content: context}]
  defp input(%Prompt{history: history}), do: Enum.flat_map(history, &turn/1)

  defp turn(%{"user" => text}), do: [%{role: "user", content: text}]

  defp turn(%{"model" => %{"output" => output}, "outputs" => outputs}) do
    calls = Enum.zip(function_calls(output), outputs)

    output ++
      Enum.map(calls, fn {call, out} -> function_call_output(call["call_id"], {:ok, out}) end)
  end

  defp function_tool(%{name: name, description: description, parameters: parameters}) do
    %{
      type: "function",
      name: name,
      description: description,
      parameters: HTTP.parameters_schema(parameters)
    }
  end

  defp loop(client, tools, input, call, record, catalog, execution) do
    with {:ok, %{"output" => output} = reply} <- post(client, request_body(client, tools, input)),
         :ok <- record.(Map.put(reply, "model", reply["model"] || client.model)) do
      case function_calls(output) do
        [] ->
          {:ok, output_text(output)}

        calls ->
          results =
            Enum.map(calls, &run_tool_call(&1, call, catalog, execution, client.media_types))

          loop(client, tools, input ++ output ++ results, call, record, catalog, execution)
      end
    end
  end

  defp request_body(client, tools, input) do
    %{model: client.model, input: input, tools: tools}
    |> Maps.maybe_put(:instructions, if(client.instructions != "", do: client.instructions))
    |> Maps.maybe_put(:temperature, client.temperature)
    |> Maps.maybe_put(:prompt_cache_key, client.prompt_cache_key)
    |> Maps.maybe_put(:stream, client.stream || nil)
    |> Body.merge(client.body)
  end

  defp post(%{stream: true} = client, body) do
    case EventStream.post(client, body, nil, &event(&1, &2, client)) do
      {:ok, %{"output" => _output} = reply} -> {:ok, reply}
      {:ok, _incomplete} -> {:error, {:openai, {:invalid_response, :incomplete}}}
      {:error, reason} -> {:error, {:openai, reason}}
    end
  end

  defp post(client, body) do
    case HTTP.post(client, body) do
      {:ok, response_body} -> extract_output(response_body)
      {:error, reason} -> {:error, {:openai, reason}}
    end
  end

  defp extract_output(%{"output" => output} = body) when is_list(output), do: {:ok, reply(body)}
  defp extract_output(body), do: {:error, {:openai, {:invalid_response, body}}}

  defp reply(response),
    do:
      %{"output" => response["output"]}
      |> Maps.maybe_put("usage", response["usage"])
      |> Maps.maybe_put("model", response["model"])

  defp event(%{"type" => "response.output_text.delta", "delta" => text}, output, client)
       when is_binary(text) do
    :ok = client.delta.(text)
    output
  end

  defp event(
         %{"type" => "response.completed", "response" => %{"output" => output} = response},
         _,
         _
       )
       when is_list(output),
       do: reply(response)

  defp event(_other, output, _client), do: output

  defp function_calls(output) do
    Enum.filter(output, fn
      %{"type" => "function_call"} -> true
      _ -> false
    end)
  end

  defp output_text(output) do
    output
    |> Enum.flat_map(&text_chunks/1)
    |> Enum.join()
  end

  defp text_chunks(%{"type" => "message", "content" => content}) when is_list(content) do
    Enum.flat_map(content, &text_chunks/1)
  end

  defp text_chunks(%{"type" => "output_text", "text" => text}) when is_binary(text), do: [text]
  defp text_chunks(%{"text" => text}) when is_binary(text), do: [text]
  defp text_chunks(_item), do: []

  defp run_tool_call(
         %{"call_id" => id, "name" => name, "arguments" => arguments},
         call,
         catalog,
         execution,
         media_types
       ) do
    function_call_output(id, HTTP.run(name, arguments, call, catalog, execution), media_types)
  end

  # A result that shows media is a list of items: its text, then the
  # images and files.
  defp function_call_output(id, result, media_types \\ nil)

  defp function_call_output(id, {:ok, result}, media_types) do
    {text, media} = Media.render(result, media_types)
    %{type: "function_call_output", call_id: id, output: output(text, media)}
  end

  defp function_call_output(id, {:error, reason}, _media_types),
    do: %{type: "function_call_output", call_id: id, output: Omunculus.Tools.Out.failure(reason)}

  defp output(text, []), do: text

  defp output(text, media),
    do: [%{type: "input_text", text: text} | Enum.map(media, &media_item/1)]

  defp media_item(%{"media_type" => "application/pdf", "name" => name} = part),
    do: %{type: "input_file", filename: name, file_data: Media.data_url(part)}

  defp media_item(part), do: %{type: "input_image", image_url: Media.data_url(part)}
end
