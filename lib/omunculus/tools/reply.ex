defmodule Omunculus.Tools.Reply do
  @moduledoc """
  Builtin `reply` tool, per spec §3.5 and §5: answers a `request` with a
  `grant` or `deny` decision and a comment body, with an optional `scope`
  for a permanent ceiling grant. Triggered from both the CLI and a model.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(request_id decision body)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil ->
        body =
          %{
            "request_id" => args["request_id"],
            "decision" => args["decision"],
            "body" => args["body"]
          }
          |> Args.put_present("scope", args)

        Out.ok("", [%{"type" => "reply", "body" => body}])

      message ->
        Out.fail(message)
    end
  end
end
