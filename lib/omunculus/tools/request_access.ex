defmodule Omunculus.Tools.RequestAccess do
  @moduledoc """
  Builtin `request_access` tool, per spec §3.5: emits a `request` for a
  `kind`/`name` with a `reason`; the store classifies the name against the
  run's ceiling and decides whether it opens a `REQUESTS` row.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(kind name reason)
  @kinds ~w(tool path directory resource)
  @resources ~w(sandbox.write sandbox.network)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil -> validate(args)
      message -> Out.fail(message)
    end
  end

  defp validate(%{"kind" => "resource", "name" => name} = args) when name in @resources,
    do: emit(args)

  defp validate(%{"kind" => "resource", "name" => name}),
    do: Out.fail("unsupported resource: #{name}")

  defp validate(%{"kind" => kind} = args) when kind in @kinds, do: emit(args)

  defp validate(%{"kind" => kind}), do: Out.fail("unsupported access kind: #{kind}")

  defp emit(args) do
    body = %{"kind" => args["kind"], "name" => args["name"], "reason" => args["reason"]}
    Out.ok("", [%{"type" => "request", "body" => body}])
  end
end
