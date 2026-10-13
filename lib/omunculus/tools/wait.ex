defmodule Omunculus.Tools.Wait do
  @moduledoc """
  Builtin `wait` tool: emits `wait` with the `report`, which parks a root
  work until its person's next message reopens it, with the report as its
  comment. Its manifest's `then` appends `end`. A run without a work has
  nothing to park: it is told to answer instead.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{work_id: nil}), do: Out.fail(Out.no_work())

  def run(%{args: args}) do
    case Args.fetch(args, "report") do
      {:ok, report} -> Out.ok("", [%{"type" => "wait", "body" => %{"body" => report}}])
      {:error, message} -> Out.fail(message)
    end
  end
end
