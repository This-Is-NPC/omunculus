defmodule Omunculus.Tools.Notify do
  @moduledoc """
  Builtin `notify` tool, per spec §3.6: tells the human through the inbox.
  The run continues; the work does not wait.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: %{"body" => text} = args}) when is_binary(text) and text != "" do
    body = Args.put_present(%{"body" => text}, "work_id", args)

    Out.ok("", [%{"type" => "notify", "body" => body}])
  end

  def run(_input) do
    Out.fail("body required")
  end
end
