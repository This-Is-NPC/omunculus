defmodule Omunculus.Tools.Retire do
  @moduledoc """
  Builtin `retire` tool: emits `retire` for `work_id`, a work below the
  run's own that broke, with the `report` as its comment, which cancels
  it. The run goes on, free to delegate once no broken work waits on it.
  A run without a work has none below it: it is told to answer instead.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{work_id: nil}), do: Out.fail(Out.no_work())

  def run(%{args: args}) do
    with {:ok, work_id} <- Args.fetch(args, "work_id"),
         {:ok, report} <- Args.fetch(args, "report") do
      Out.ok("", [%{"type" => "retire", "body" => %{"work_id" => work_id, "body" => report}}])
    else
      {:error, message} -> Out.fail(message)
    end
  end
end
