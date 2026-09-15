defmodule Omunculus.Tools.InboxRead do
  @moduledoc """
  Builtin `inbox_read` tool, per spec §3.6: marks an `INBOX` entry as read.
  """

  @spec run(map) :: map
  def run(%{args: %{"inbox_id" => id}}) when is_binary(id) and id != "" do
    %{
      "ok" => true,
      "output" => "",
      "emit" => [%{"type" => "inbox.read", "body" => %{"inbox_id" => id}}]
    }
  end

  def run(_input) do
    %{"ok" => false, "output" => "inbox_id required", "emit" => []}
  end
end
