defmodule Omunculus.Tools.Break do
  @moduledoc """
  Builtin `break` tool, per spec §3.4: emits `break` with the `report`,
  which parks the work with the report as its comment and hands it back
  to a parent waiting on it. The sequence does not advance. Its
  manifest's `then` appends `end`. A run without a work has nothing to
  break: it is told to answer instead.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{work_id: nil}), do: Out.fail(Out.no_work())

  def run(%{args: args}) do
    case Args.fetch(args, "report") do
      {:ok, report} -> Out.ok("", [%{"type" => "break", "body" => %{"body" => report}}])
      {:error, message} -> Out.fail(message)
    end
  end
end
