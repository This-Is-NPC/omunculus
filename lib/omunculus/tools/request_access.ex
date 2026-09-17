defmodule Omunculus.Tools.RequestAccess do
  @moduledoc """
  Builtin `request_access` tool, per spec §3.5: emits a `request` for a
  tool, path, or directory. Sandbox capabilities go through `request_sandbox`.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(kind name reason)
  @kinds ~w(tool path directory)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil -> validate(args)
      message -> Out.fail(message)
    end
  end

  defp validate(%{"kind" => kind} = args) when kind in @kinds, do: emit(args)

  defp validate(%{"kind" => kind}), do: Out.fail("unsupported access kind: #{kind}")

  defp emit(args) do
    body = %{"kind" => args["kind"], "name" => args["name"], "reason" => args["reason"]}
    Out.ok("", [%{"type" => "request", "body" => body}])
  end
end
