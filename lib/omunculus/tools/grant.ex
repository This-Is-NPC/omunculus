defmodule Omunculus.Tools.Grant do
  @moduledoc """
  Builtin `grant` tool, a chain step of `reply`: emits `grant` with the
  `request_id`, the `name` and `kind` to grant and an optional `scope`.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(request_id name kind)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil ->
        body = args |> Map.take(@required) |> Args.put_present("scope", args)
        Out.ok("", [%{"type" => "grant", "body" => body}])

      message ->
        Out.fail(message)
    end
  end
end
