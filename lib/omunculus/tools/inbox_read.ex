defmodule Omunculus.Tools.InboxRead do
  @moduledoc """
  Builtin `inbox_read` tool, per spec §3.6: marks an `INBOX` entry as read.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{args: %{"inbox_id" => id}}) when is_binary(id) and id != "" do
    Out.ok("", [%{"type" => "inbox.read", "body" => %{"inbox_id" => id}}])
  end

  def run(_input) do
    Out.fail("inbox_id required")
  end
end
