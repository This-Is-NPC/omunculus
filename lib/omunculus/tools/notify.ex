defmodule Omunculus.Tools.Notify do
  @moduledoc """
  Builtin `notify` tool, per spec §3.6: tells the human through the inbox.
  The run continues; the work does not wait.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.fetch(args, "body") do
      {:ok, text} ->
        body = Args.put_present(%{"body" => text}, "work_id", args)
        Out.ok("", [%{"type" => "notify", "body" => body}])

      {:error, message} ->
        Out.fail(message)
    end
  end
end
