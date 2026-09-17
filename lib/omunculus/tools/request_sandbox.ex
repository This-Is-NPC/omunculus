defmodule Omunculus.Tools.RequestSandbox do
  @moduledoc """
  Builtin `request_sandbox` tool: emits a `request` with `kind = resource`
  for a sandbox capability named in `[execution] resources`. The store
  classifies that name against the run's ceiling.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(name reason)
  @resources ~w(sandbox.write sandbox.network)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil -> validate(args)
      message -> Out.fail(message)
    end
  end

  defp validate(%{"name" => name} = args) when name in @resources, do: emit(args)

  defp validate(%{"name" => name}), do: Out.fail("unsupported resource: #{name}")

  defp emit(args) do
    body = %{"kind" => "resource", "name" => args["name"], "reason" => args["reason"]}
    Out.ok("", [%{"type" => "request", "body" => body}])
  end
end
