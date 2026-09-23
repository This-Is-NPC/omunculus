defmodule Omunculus.Tools.RequestAccess do
  @moduledoc """
  Builtin `request_access` tool, per spec §3.5: emits a `request` for a
  tool, path, or directory. Sandbox capabilities go through `request_sandbox`.
  In a run with a work, a `comment` with the `report` on that work comes
  first. Its manifest's `then` appends `end`.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(report kind name reason)
  @kinds ~w(tool path directory)

  @spec run(map) :: map
  def run(%{args: args} = input) do
    case Args.missing(args, @required) do
      nil -> validate(input)
      message -> Out.fail(message)
    end
  end

  defp validate(%{args: %{"kind" => kind} = args} = input) when kind in @kinds,
    do: emit(input, Map.take(args, ~w(kind name reason)))

  defp validate(%{args: %{"kind" => kind}}), do: Out.fail("unsupported access kind: #{kind}")

  @doc """
  The emits of a request tool: the `report` as a comment on the run's
  work, when it has one, then the `request` with `body`.
  """
  @spec emit(map, map) :: map
  def emit(%{args: %{"report" => report}, work_id: work_id}, body) do
    comment =
      if work_id,
        do: [%{"type" => "comment", "body" => %{"work_id" => work_id, "body" => report}}],
        else: []

    Out.ok("", comment ++ [%{"type" => "request", "body" => body}])
  end
end
