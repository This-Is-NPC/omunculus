defmodule Omunculus.Tools.InboxRead do
  @moduledoc """
  Builtin `inbox_read` tool, per spec §3.6: marks an `INBOX` entry as read.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.fetch(args, "inbox_id") do
      {:ok, id} -> Out.ok("", [%{"type" => "inbox.read", "body" => %{"inbox_id" => id}}])
      {:error, message} -> Out.fail(message)
    end
  end
end
