defmodule Omunculus.Tools.Comment do
  @moduledoc """
  Builtin `comment` tool: writes a comment on a work, request or inbox.
  Without an explicit target, falls back to the run's work.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args} = input) do
    case Args.fetch(args, "body") do
      {:ok, text} -> comment(Map.take(args, ~w(work_id request_id inbox_id)), text, input)
      {:error, message} -> Out.fail(message)
    end
  end

  defp comment(targets, text, input) do
    targets =
      if map_size(targets) == 0 and input.work_id,
        do: %{"work_id" => input.work_id},
        else: targets

    if map_size(targets) == 0 do
      Out.fail("no work to comment on")
    else
      Out.ok("", [%{"type" => "comment", "body" => Map.put(targets, "body", text)}])
    end
  end
end
