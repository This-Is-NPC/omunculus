defmodule Omunculus.Model.OpenAI do
  @moduledoc """
  Factory for an OpenAI-compatible model of the contract of spec §8.6:
  `new/1` takes the `[models.<name>]` spec (`url`, `model`, `timeout_ms`,
  optional `temperature`, `headers`, `credential`) and returns a 5-arity
  `(assembled, tools, call, record, execution)` fun. Declares each of
  `tools` (the run's effective tools, as `%{name, description,
  parameters}`) as a function with its real `parameters` schema — an
  empty schema becomes `%{type: "object", properties: %{}}` so servers
  accept it — posts the assembled as the user turn to
  `<url>/chat/completions`, and for every `tool_calls` entry in the
  reply runs `call.(name, args)` and feeds the output back as a `tool`
  message, looping until a reply carries no tool call. Every reply is
  recorded before dispatch. `__omunculus_execute` runs JavaScript in the
  sandbox and uses the same authorized call callback as native tool
  calls.
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
      url: spec["url"] <> "/chat/completions",
      model: spec["model"],
      timeout: spec["timeout_ms"],
      headers: request_headers(spec),
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

  @doc false
  def request_headers(spec) do
    explicit = headers_list(Map.get(spec, "headers"))

    case Map.get(spec, "credential") do
      %{"access" => access} when is_binary(access) and access != "" ->
        [{"authorization", "Bearer " <> access} | explicit]

      %{access: access} when is_binary(access) and access != "" ->
        [{"authorization", "Bearer " <> access} | explicit]

      _absent ->
        explicit
    end
  end

  defp headers_list(nil), do: []
  defp headers_list(headers) when is_list(headers), do: headers

  defp headers_list(headers) when is_map(headers),
    do: Enum.map(headers, fn {key, value} -> {key, value} end)

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
      function: %{name: name, description: description, parameters: parameters_schema(parameters)}
    }
  end

  @doc false
  def parameters_schema(parameters) when map_size(parameters) == 0,
    do: %{type: "object", properties: %{}}

  def parameters_schema(parameters), do: parameters

  defp loop(client, tools, messages, call, record, catalog, execution) do
    with {:ok, message} <- post(client, request_body(client, tools, messages)),
         :ok <- record.(strip_message(message)) do
      case message do
        %{"tool_calls" => [_ | _] = tool_calls} ->
          with {:ok, tool_messages} <- run_tool_calls(tool_calls, call, catalog, execution) do
            loop(
              client,
              tools,
              messages ++ [strip_message(message) | tool_messages],
              call,
              record,
              catalog,
              execution
            )
          end

        _final ->
          {:ok, message["content"] || ""}
      end
    end
  end

  defp request_body(client, tools, messages) do
    %{model: client.model, messages: messages, tools: tools}
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
        extract_message(response_body)

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:openai, {:http, status, response_body}}}

      {:error, reason} ->
        {:error, {:openai, reason}}
    end
  end

  defp extract_message(%{"choices" => [%{"message" => message} | _]}), do: {:ok, message}
  defp extract_message(body), do: {:error, {:openai, {:invalid_response, body}}}

  defp run_tool_calls(tool_calls, call, catalog, execution) do
    Enum.reduce_while(tool_calls, {:ok, []}, fn tool_call, {:ok, acc} ->
      case run_tool_call(tool_call, call, catalog, execution) do
        {:ok, tool_message} -> {:cont, {:ok, acc ++ [tool_message]}}
        {:error, reason} -> {:halt, {:error, {:openai, reason}}}
      end
    end)
  end

  defp run_tool_call(
         %{"id" => id, "function" => %{"name" => name, "arguments" => arguments}},
         call,
         catalog,
         execution
       ) do
    with {:ok, args} <- decode_arguments(arguments) do
      {:ok, tool_result_message(id, invoke(name, args, call, catalog, execution))}
    end
  end

  defp invoke("__omunculus_execute", %{"code" => code}, call, catalog, execution)
       when is_binary(code),
       do: Omunculus.Sandbox.run(code, catalog, call, execution)

  defp invoke(name, args, call, _catalog, _execution), do: call.(name, args)

  defp decode_arguments(""), do: {:ok, %{}}

  defp decode_arguments(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_arguments, reason}}
    end
  end

  defp tool_result_message(id, {:ok, output}),
    do: %{role: "tool", tool_call_id: id, content: output}

  defp tool_result_message(id, {:error, reason}),
    do: %{role: "tool", tool_call_id: id, content: inspect(reason)}

  defp strip_message(message), do: Map.take(message, ["role", "content", "tool_calls"])
end
