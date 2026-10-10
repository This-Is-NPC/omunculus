defmodule Omunculus.Tools.Reopen do
  @moduledoc """
  Builtin `reopen` tool: emits `reopen` for `work_id`, a work below the
  run's own that broke, with `instructions` on how to go on, which reopens
  it, comments them on it and runs its agent again, or the `agent` it
  names at that depth. Its manifest's `then`
  appends `end`.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args}) do
    with {:ok, work_id} <- Args.fetch(args, "work_id"),
         {:ok, instructions} <- Args.fetch(args, "instructions") do
      body = Args.put_present(%{"work_id" => work_id, "body" => instructions}, "agent", args)
      Out.ok("", [%{"type" => "reopen", "body" => body}])
    else
      {:error, message} -> Out.fail(message)
    end
  end
end
