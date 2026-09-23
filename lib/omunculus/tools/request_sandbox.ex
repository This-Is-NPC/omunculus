defmodule Omunculus.Tools.RequestSandbox do
  @moduledoc """
  Builtin `request_sandbox` tool: emits a `request` with `kind = resource`
  for a sandbox capability named in `[execution] resources`. The store
  classifies that name against the run's ceiling. Like `request_access`,
  the `report` is commented on the run's work first and the manifest's
  `then` appends `end`.
  """

  alias Omunculus.Tools.{Args, Out, RequestAccess}

  @required ~w(report name reason)
  @resources ~w(sandbox.write sandbox.network)

  @spec run(map) :: map
  def run(%{args: args} = input) do
    case Args.missing(args, @required) do
      nil -> validate(input)
      message -> Out.fail(message)
    end
  end

  defp validate(%{args: %{"name" => name} = args} = input) when name in @resources do
    RequestAccess.emit(input, %{"kind" => "resource", "name" => name, "reason" => args["reason"]})
  end

  defp validate(%{args: %{"name" => name}}), do: Out.fail("unsupported resource: #{name}")
end
