defmodule Omunculus.Tools.Delegate do
  @moduledoc """
  Builtin `delegate` tool, per spec §3.4: creates a child work and hands it
  to whoever is below. The parent waits.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(title body)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil ->
        body = %{"title" => args["title"], "body" => args["body"]}
        Out.ok("", [%{"type" => "delegate", "body" => body}])

      message ->
        Out.fail(message)
    end
  end
end
