defmodule Omunculus.Model.OpenAIResponses do
  @moduledoc """
  Factory for an OpenAI Responses model of the contract of spec §8.6:
  `new/1` takes the `[models.<name>]` spec (`url`, `model`, `timeout_ms`,
  optional `temperature`, `headers`, `credential`) and returns a 5-arity
  `(assembled, tools, call, record, execution)` fun. Posts the assembled
  as `input` to `<url>/responses` with tools as `function` items, runs
  each `function_call` through `call.(name, args)`, appends
  `function_call_output`, and loops until a reply has none.
  `__omunculus_execute` is the same sandbox bridge as `Model.OpenAI`.
  The `url` is always the spec's; nothing in this module names a host.
  """

  @spec new(map) ::
          (String.t(),
           [map],
           (String.t(), map -> {:ok, String.t()} | {:error, term}),
           (map -> :ok | {:error, term}),
           Omunculus.Execution.Policy.t() ->
             {:ok, String.t()} | {:error, term})
  def new(spec) when is_map(spec) do
    client = %{
      url: spec["url"] <> "/responses",
      model: spec["model"],
      timeout: spec["timeout_ms"],
      headers: Omunculus.Model.OpenAI.request_headers(spec),
      temperature: spec["temperature"]
    }

    fn assembled, tools, call, record, execution ->
      function_tools = Enum.map(tools, &function_tool/1) ++ [executor_tool()]

      loop(
        client,
        function_tools,
        [%{role: "user", content: assembled}],
        call,
        record,
        tools,
        execution
      )
    end
  end

  defp executor_tool do
    function_tool(%{
      name: "__omunculus_execute",
      description:
        "Execute JavaScript with await tools.<name>(args). Return the result. No direct filesystem, network or process access.",
      parameters: %{
        type: "object",
        properties: %{code: %{type: "string"}},
        required: ["code"],
        additionalProperties: false
      }
    })
  end

  defp function_tool(%{name: name, description: description, parameters: parameters}) do
    %{
      type: "function",
      name: name,
      description: description,
      parameters: Omunculus.Model.OpenAI.parameters_schema(parameters)
    }
  end

  defp loop(client, tools, input, call, record, catalog, execution) do
    with {:ok, output} <- post(client, request_body(client, tools, input)),
         :ok <- record.(%{"output" => output}) do
      case function_calls(output) do
        [] ->
          {:ok, output_text(output)}

        calls ->
          with {:ok, results} <- run_tool_calls(calls, call, catalog, execution) do
            loop(
              client,
              tools,
              input ++ output ++ results,
              call,
              record,
              catalog,
              execution
            )
          end
      end
    end
  end

  defp request_body(client, tools, input) do
    %{model: client.model, input: input, tools: tools}
    |> maybe_put(:temperature, client.temperature)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp post(client, body) do
    case Req.post(client.url,
           json: body,
           headers: client.headers,
           receive_timeout: client.timeout
         ) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        extract_output(response_body)

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:openai, {:http, status, response_body}}}

      {:error, reason} ->
        {:error, {:openai, reason}}
    end
  end

  defp extract_output(%{"output" => output}) when is_list(output), do: {:ok, output}
  defp extract_output(body), do: {:error, {:openai, {:invalid_response, body}}}

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

  defp run_tool_calls(tool_calls, call, catalog, execution) do
    Enum.reduce_while(tool_calls, {:ok, []}, fn tool_call, {:ok, acc} ->
      case run_tool_call(tool_call, call, catalog, execution) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        {:error, reason} -> {:halt, {:error, {:openai, reason}}}
      end
    end)
  end

  defp run_tool_call(
         %{"call_id" => id, "name" => name, "arguments" => arguments},
         call,
         catalog,
         execution
       ) do
    with {:ok, args} <- decode_arguments(arguments) do
      {:ok, function_call_output(id, invoke(name, args, call, catalog, execution))}
    end
  end

  defp invoke("__omunculus_execute", %{"code" => code}, call, catalog, execution)
       when is_binary(code),
       do: Omunculus.Sandbox.run(code, catalog, call, execution)

  defp invoke(name, args, call, _catalog, _execution), do: call.(name, args)

  defp decode_arguments(""), do: {:ok, %{}}

  defp decode_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_arguments, reason}}
    end
  end

  defp decode_arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  defp function_call_output(id, {:ok, output}),
    do: %{type: "function_call_output", call_id: id, output: output}

  defp function_call_output(id, {:error, reason}),
    do: %{type: "function_call_output", call_id: id, output: inspect(reason)}
end
