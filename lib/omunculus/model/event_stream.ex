defmodule Omunculus.Model.EventStream do
  @moduledoc """
  Posts a streaming request of an HTTP model adapter and folds the
  server-sent events of a successful reply, in the caller, as they
  arrive. `fold` gets each event's decoded `data` (`[DONE]` is skipped)
  and the accumulator. A reply outside 2xx is returned whole as
  `{:http, status, body}`.
  """

  @state :omunculus_event_stream

  @spec post(map, map, acc, (map, acc -> acc)) :: {:ok, acc} | {:error, term} when acc: term
  def post(client, body, acc, fold) do
    into = fn {:data, data}, {req, resp} ->
      {buffer, acc} = Req.Response.get_private(resp, @state, {"", acc})

      {:cont,
       {req, Req.Response.put_private(resp, @state, consume(buffer <> data, acc, resp, fold))}}
    end

    case Req.post(client.url,
           json: body,
           headers: client.headers,
           receive_timeout: client.timeout,
           compressed: false,
           into: into
         ) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {rest, acc} = Req.Response.get_private(resp, @state, {"", acc})
        {:ok, rest |> blocks() |> Enum.reduce(acc, &fold_block(&1, &2, fold))}

      {:ok, %Req.Response{status: status} = resp} ->
        {rest, _acc} = Req.Response.get_private(resp, @state, {"", acc})
        {:error, {:http, status, decode(rest)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume(buffer, acc, %Req.Response{status: status}, fold) when status in 200..299 do
    buffer = String.replace(buffer, "\r\n", "\n")

    case String.split(buffer, "\n\n") do
      [partial] ->
        {partial, acc}

      parts ->
        {complete, [partial]} = Enum.split(parts, -1)
        {partial, Enum.reduce(complete, acc, &fold_block(&1, &2, fold))}
    end
  end

  defp consume(buffer, acc, _resp, _fold), do: {buffer, acc}

  defp blocks(rest), do: rest |> String.replace("\r\n", "\n") |> String.split("\n\n")

  defp fold_block(block, acc, fold) do
    data =
      block
      |> String.split("\n")
      |> Enum.flat_map(fn
        "data:" <> value -> [String.trim_leading(value, " ")]
        _other -> []
      end)
      |> Enum.join("\n")

    case data do
      "" -> acc
      "[DONE]" -> acc
      json -> fold.(Jason.decode!(json), acc)
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end
end
