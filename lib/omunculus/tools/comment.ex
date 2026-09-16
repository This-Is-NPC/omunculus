defmodule Omunculus.Tools.Comment do
  @moduledoc """
  Builtin `comment` tool, per spec §8.5: writes a comment on a work, request or inbox.
  Without an explicit target, falls back to the run's work.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{args: %{"body" => text} = args} = input) when is_binary(text) and text != "" do
    targets = Map.take(args, ~w(work_id request_id inbox_id))

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

  def run(_input) do
    Out.fail("body required")
  end
end
