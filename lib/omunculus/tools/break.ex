defmodule Omunculus.Tools.Break do
  @moduledoc """
  Builtin `break` tool, per spec §3.4: parks the work with a comment. The
  sequence does not advance.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(body)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil ->
        body = %{"body" => args["body"]}
        Out.ok("", [%{"type" => "break", "body" => body}])

      message ->
        Out.fail(message)
    end
  end
end
