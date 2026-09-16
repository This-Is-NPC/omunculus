defmodule Omunculus.Model.OpenAI do
  @moduledoc """
  Factory for an OpenAI-compatible model of the contract of spec §8.6:
  `new/3` returns a `(assembled, call) :: {:ok, text} | {:error, term}`
  fun. Declares the cards the assembled prompt's `## Tools` section names
  (`Omunculus.Model.Cards`) as functions with a permissive
  `%{type: "object", additionalProperties: true}` schema, posts
  `<base_url>/chat/completions`, and for every `tool_calls` entry in the
  reply runs `call.(name, args)` and feeds the output back as a `tool`
  message, looping until a reply carries no tool call.
  """

  alias Omunculus.Model.Cards

  @default_timeout 120_000

  @spec new(String.t(), String.t(), keyword) ::
          (String.t(), (String.t(), map -> {:ok, String.t()} | {:error, term}) ->
             {:ok, String.t()} | {:error, term})
  def new(base_url, model_name, opts \\ []) do
    client = %{
      url: base_url <> "/chat/completions",
      model: model_name,
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      headers: Keyword.get(opts, :headers, []),
      temperature: Keyword.get(opts, :temperature)
    }

    fn assembled, call ->
      tools = assembled |> Cards.names() |> Enum.sort() |> Enum.map(&function_tool/1)
      loop(client, tools, [%{role: "system", content: assembled}], call)
    end
  end

  defp function_tool(name) do
    %{
      type: "function",
      function: %{name: name, parameters: %{type: "object", additionalProperties: true}}
    }
  end

  defp loop(client, tools, messages, call) do
    with {:ok, message} <- post(client, request_body(client, tools, messages)) do
      case message do
        %{"tool_calls" => [_ | _] = tool_calls} ->
          with {:ok, tool_messages} <- run_tool_calls(tool_calls, call) do
            loop(client, tools, messages ++ [strip_message(message) | tool_messages], call)
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

  defp run_tool_calls(tool_calls, call) do
    Enum.reduce_while(tool_calls, {:ok, []}, fn tool_call, {:ok, acc} ->
      case run_tool_call(tool_call, call) do
        {:ok, tool_message} -> {:cont, {:ok, acc ++ [tool_message]}}
        {:error, reason} -> {:halt, {:error, {:openai, reason}}}
      end
    end)
  end

  defp run_tool_call(
         %{"id" => id, "function" => %{"name" => name, "arguments" => arguments}},
         call
       ) do
    with {:ok, args} <- decode_arguments(arguments) do
      {:ok, tool_result_message(id, call.(name, args))}
    end
  end

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
