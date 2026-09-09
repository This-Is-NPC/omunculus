defmodule Omunculus.Chat.Completions do
  @moduledoc false
  @behaviour Omunculus.Chat

  @impl true
  def complete(chat, messages, tools) do
    url = upstream(chat.base_url) <> "/chat/completions"
    timeout = chat.timeout_ms

    body =
      %{
        "model" => chat.model,
        "messages" => messages,
        "stream" => false
      }
      |> maybe_put_tools(tools)

    headers = [{"content-type", "application/json"}] ++ Omunculus.Auth.headers(chat.auth)

    case Req.post(url, json: body, headers: headers, receive_timeout: timeout, retry: false) do
      {:ok, %Req.Response{status: status, body: decoded}} when status in 200..299 ->
        decode(decoded)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, excerpt(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def new(opts) do
    %{
      mod: __MODULE__,
      base_url: Keyword.fetch!(opts, :base_url),
      model: Keyword.fetch!(opts, :model),
      auth: Keyword.fetch!(opts, :auth),
      timeout_ms:
        case Keyword.get(opts, :timeout_ms, 120_000) do
          "infinity" -> :infinity
          value when is_integer(value) and value > 0 -> value
        end
    }
  end

  def upstream(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.trim_trailing("/v1")
    |> Kernel.<>("/v1")
  end

  defp maybe_put_tools(body, tools) when is_list(tools) and tools != [],
    do: Map.put(body, "tools", tools)

  defp maybe_put_tools(body, _), do: body

  defp decode(decoded) when is_map(decoded) do
    choice = decoded |> Map.get("choices", []) |> List.first() || %{}
    message = choice["message"] || %{}
    tool_calls = message["tool_calls"]

    {:ok,
     %{
       content: message["content"],
       tool_calls: if(tool_calls in [nil, []], do: nil, else: tool_calls),
       usage: decoded["usage"]
     }}
  end

  defp decode(other), do: {:error, {:invalid_json, other}}

  defp excerpt(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp excerpt(body), do: body |> inspect() |> String.slice(0, 300)
end
