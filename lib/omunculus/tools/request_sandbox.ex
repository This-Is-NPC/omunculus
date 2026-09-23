defmodule Omunculus.Tools.RequestSandbox do
  @moduledoc """
  Builtin `request_sandbox` tool: emits a `request` with `kind = resource`
  for a sandbox capability named in `[execution] resources`, with the
  options of `request_access`. The store classifies that name against the
  run's ceiling. Like `request_access`, the `report` is commented on the
  run's work first and the manifest's `then` appends `end`.
  """

  alias Omunculus.Config
  alias Omunculus.Tools.{Args, Out, RequestAccess}

  @required ~w(report name reason)

  @spec run(map) :: map
  def run(%{args: args} = input) do
    case Args.missing(args, @required) do
      nil -> validate(input)
      message -> Out.fail(message)
    end
  end

  defp validate(%{args: %{"name" => name}} = input) do
    if name in Config.known_resources(),
      do: RequestAccess.emit(input, "resource", name),
      else: Out.fail("unsupported resource: #{name}")
  end
end
