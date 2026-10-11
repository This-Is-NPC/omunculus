defmodule Omunculus.Tools.Record do
  @moduledoc """
  The record of a run as lines for a model: the message that opened it,
  then every event it recorded but its start and end and the calls of the
  tool named `hidden` — that is the model's messages as recorded but their
  `usage`, each tool call with its args, status and output, and each store
  action it emitted. With a `limit`, each call's output keeps that many
  bytes, cut on a character boundary, and a line says how many were cut.
  """

  alias Omunculus.Tools.Out

  @doc "The text of a recorded model reply, its JSON or decoded, in each provider's shape."
  @spec said(String.t() | map) :: String.t()
  def said(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, reply} when is_map(reply) -> said(reply)
      _not_a_reply -> ""
    end
  end

  def said(reply) when is_map(reply), do: reply |> texts() |> Enum.join("\n")

  defp texts(%{"content" => text}) when is_binary(text), do: [text]

  defp texts(%{"content" => blocks}) when is_list(blocks),
    do: for(%{"type" => "text", "text" => text} <- blocks, do: text)

  defp texts(%{"output" => items}) when is_list(items) do
    for %{"type" => "message", "content" => parts} <- items,
        %{"type" => "output_text", "text" => text} <- parts,
        do: text
  end

  defp texts(_reply), do: []

  @spec lines(map, String.t(), pos_integer | nil) :: [String.t()]
  def lines(run, hidden, limit) do
    message = if run.message, do: ["- message #{run.message.body}"], else: []
    message ++ Enum.flat_map(run.events, &entry(&1, hidden, limit))
  end

  # The lifecycle events say nothing of what the run did.
  defp entry(%{type: type}, _hidden, _limit) when type in ["start-run", "end-run"], do: []

  defp entry(%{type: "tool", body: body}, hidden, limit) do
    case Jason.decode!(body) do
      %{"name" => ^hidden} -> []
      call -> [call_entry(call, limit)]
    end
  end

  defp entry(%{type: type, body: body}, _hidden, _limit), do: ["- #{type} #{shown(type, body)}"]

  # The usage a server reports on a reply is for measuring the run, not
  # something the next run acts on.
  defp shown("model", body) do
    case Jason.decode(body) do
      {:ok, %{"usage" => _usage} = reply} -> Jason.encode!(Map.delete(reply, "usage"))
      _other -> body
    end
  end

  defp shown(_type, body), do: body

  defp call_entry(call, limit) do
    via = if call["via"], do: " via #{call["via"]}", else: ""
    status = if call["ok"], do: "ok", else: "failed"
    head = "- tool #{call["name"]}#{via} #{Jason.encode!(call["args"])} #{status}"

    case call["output"] do
      output when output in [nil, ""] -> head
      output when is_binary(output) -> head <> "\n" <> Out.cut(output, limit)
      output -> head <> "\n" <> Out.cut(Jason.encode!(output), limit)
    end
  end
end
