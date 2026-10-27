defmodule Omunculus.Model.HTTP do
  @moduledoc """
  What the HTTP model adapters share: the client a `[models.<name>]` spec
  makes, the tools a run declares (with `__omunculus_execute` under
  `code_mode`), a tool call decoded and dispatched to `call` or the
  sandbox, and a request posted without streaming. A reply outside 2xx
  is returned whole as `{:http, status, body}`, as `EventStream` does.
  """

  alias Omunculus.Model.{Arguments, Retry}

  @executor "__omunculus_execute"

  @spec client(map, String.t(), [{String.t(), String.t()}]) :: map
  def client(spec, path, headers) do
    %{
      url: spec["url"] <> path,
      model: spec["model"],
      timeout: spec["timeout_ms"],
      retries: spec["retries"],
      code_mode: spec["code_mode"] == true,
      headers: headers,
      temperature: spec["temperature"],
      stream: spec["stream"] == true,
      prompt_cache_key: spec["prompt_cache_key"],
      body: spec["body"] || %{}
    }
  end

  @spec headers_list(nil | list | map) :: [{String.t(), String.t()}]
  def headers_list(nil), do: []
  def headers_list(headers) when is_list(headers), do: headers

  def headers_list(headers) when is_map(headers),
    do: Enum.map(headers, fn {key, value} -> {key, value} end)

  @doc "The run's tools, then the executor under `code_mode`, each in the provider's `format`."
  @spec tools(map, [map], (map -> map)) :: [map]
  def tools(client, tools, format) do
    Enum.map(tools, format) ++ if(client.code_mode, do: [format.(executor_tool())], else: [])
  end

  defp executor_tool do
    %{
      name: @executor,
      description:
        "Execute JavaScript with await tools.<name>(args). Return the result. No direct filesystem, network or process access.",
      parameters: %{
        type: "object",
        properties: %{code: %{type: "string"}},
        required: ["code"],
        additionalProperties: false
      }
    }
  end

  # An empty schema becomes an empty object schema so servers accept it.
  @spec parameters_schema(map) :: map
  def parameters_schema(parameters) when map_size(parameters) == 0,
    do: %{type: "object", properties: %{}}

  def parameters_schema(parameters), do: parameters

  @doc "Decodes a tool call's `arguments` and runs it through `call`, or the sandbox for the executor."
  @spec run(String.t(), term, function, [map], Omunculus.Execution.Policy.t()) ::
          {:ok, String.t()} | {:error, term}
  def run(name, arguments, call, catalog, execution) do
    with {:ok, args} <- Arguments.decode(arguments),
         do: invoke(name, args, call, catalog, execution)
  end

  defp invoke(@executor, %{"code" => code}, call, catalog, execution) when is_binary(code),
    do: Omunculus.Sandbox.run(code, catalog, call, execution)

  defp invoke(name, args, call, _catalog, _execution), do: call.(name, args)

  @spec post(map, map) :: {:ok, term} | {:error, term}
  def post(client, body) do
    case Req.post(
           client.url,
           [json: body, headers: client.headers, receive_timeout: client.timeout] ++
             Retry.options(client.retries)
         ) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:http, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec maybe_put(map, term, term) :: map
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)
end
