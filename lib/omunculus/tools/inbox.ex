defmodule Omunculus.Tools.Inbox do
  @moduledoc """
  Builtin `inbox` tool, per spec §3.6: lists the unread `INBOX` entries from
  the `inbox` view.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{view: view}) do
    output =
      case Map.get(view, "inbox", []) do
        [] -> "inbox vazio"
        items -> items |> Enum.map(&line/1) |> Enum.join("\n")
      end

    Out.ok(output)
  end

  defp line(%{id: id, agent: agent, body: nil}), do: "#{id} #{agent}: (sem texto)"
  defp line(%{id: id, agent: agent, body: body}), do: "#{id} #{agent}: #{body}"
end
