defmodule Omunculus.Tools.Comment do
  @moduledoc """
  Builtin `comment` tool, per spec §8.5: writes a comment on a work, either
  named in `args["work_id"]` or falling back to the run's own `work_id`.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: %{"body" => text} = args} = input) when is_binary(text) and text != "" do
    case Args.present(args, "work_id") || input.work_id do
      nil ->
        Out.fail("no work to comment on")

      work_id ->
        body = %{"work_id" => work_id, "body" => text}
        Out.ok("", [%{"type" => "comment", "body" => body}])
    end
  end

  def run(_input) do
    Out.fail("body required")
  end
end
