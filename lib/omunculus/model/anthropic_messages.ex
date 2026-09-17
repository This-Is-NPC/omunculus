defmodule Omunculus.Model.AnthropicMessages do
  @moduledoc """
  Factory for an Anthropic Messages model of the contract of spec §8.6:
  `new/1` takes the `[models.<name>]` spec (`url`, `model`, `timeout_ms`,
  optional `temperature`, `headers`, `credential`) and returns a 5-arity
  `(assembled, tools, call, record, execution)` fun. Posts the assembled
  as `system` to `<url>/messages` with tools as Anthropic `input_schema`
  items, runs each `tool_use` through `call.(name, args)`, appends a
  `tool_result` user turn, and loops until a reply has none.
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
      url: spec["url"] <> "/messages",
      model: spec["model"],
      timeout: spec["timeout_ms"],
      headers: request_headers(spec),
      temperature: spec["temperature"]
    }

    fn assembled, tools, call, record, execution ->
      function_tools = Enum.map(tools, &anthropic_tool/1) ++ [executor_tool()]

      loop(
        client,
        assembled,
        function_tools,
        [%{role: "user", content: "Proceed."}],
        call,
        record,
        tools,
        execution
      )
    end
  end

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

    base ++ cred ++ headers_list(Map.get(spec, "headers"))
  end

  defp headers_list(nil), do: []
  defp headers_list(headers) when is_list(headers), do: headers

  defp headers_list(headers) when is_map(headers),
    do: Enum.map(headers, fn {key, value} -> {key, value} end)

  defp executor_tool do
    anthropic_tool(%{
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

  defp anthropic_tool(%{name: name, description: description, parameters: parameters}) do
    %{
      name: name,
      description: description,
      input_schema: Omunculus.Model.OpenAI.parameters_schema(parameters)
    }
  end

  defp loop(client, system, tools, messages, call, record, catalog, execution) do
    with {:ok, message} <- post(client, request_body(client, system, tools, messages)),
         :ok <- record.(strip_message(message)) do
      case tool_uses(message) do
        [] ->
          {:ok, output_text(message)}

        uses ->
          with {:ok, results} <- run_tool_uses(uses, call, catalog, execution) do
            loop(
              client,
              system,
              tools,
              messages ++ [assistant_turn(message), %{role: "user", content: results}],
              call,
              record,
              catalog,
              execution
            )
          end
      end
    end
  end

  defp request_body(client, system, tools, messages) do
    %{
      model: client.model,
      max_tokens: 8192,
      system: system,
      messages: messages,
      tools: tools
    }
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
        {:error, {:anthropic, {:http, status, response_body}}}

      {:error, reason} ->
        {:error, {:anthropic, reason}}
    end
  end

  defp extract_message(%{"content" => content} = message) when is_list(content),
    do: {:ok, message}

  defp extract_message(body), do: {:error, {:anthropic, {:invalid_response, body}}}

  defp strip_message(message), do: Map.take(message, ["role", "content", "stop_reason"])

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

  defp run_tool_uses(uses, call, catalog, execution) do
    Enum.reduce_while(uses, {:ok, []}, fn use, {:ok, acc} ->
      case run_tool_use(use, call, catalog, execution) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        {:error, reason} -> {:halt, {:error, {:anthropic, reason}}}
      end
    end)
  end

  defp run_tool_use(%{"id" => id, "name" => name, "input" => input}, call, catalog, execution) do
    with {:ok, args} <- decode_input(input) do
      {:ok, tool_result(id, invoke(name, args, call, catalog, execution))}
    end
  end

  defp invoke("__omunculus_execute", %{"code" => code}, call, catalog, execution)
       when is_binary(code),
       do: Omunculus.Sandbox.run(code, catalog, call, execution)

  defp invoke(name, args, call, _catalog, _execution), do: call.(name, args)

  defp decode_input(input) when is_map(input), do: {:ok, input}

  defp decode_input(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_arguments, reason}}
    end
  end

  defp decode_input(_input), do: {:ok, %{}}

  defp tool_result(id, {:ok, output}),
    do: %{type: "tool_result", tool_use_id: id, content: output}

  defp tool_result(id, {:error, reason}),
    do: %{type: "tool_result", tool_use_id: id, content: inspect(reason)}
end
