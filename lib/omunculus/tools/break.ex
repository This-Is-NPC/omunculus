defmodule Omunculus.Tools.Break do
  @moduledoc """
  Builtin `break` tool, per spec §3.4: parks the work with a comment. The
  sequence does not advance.
  """

  alias Omunculus.Tools.Args

  @required ~w(body)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil ->
        body = %{"body" => args["body"]}
        %{"ok" => true, "output" => "", "emit" => [%{"type" => "break", "body" => body}]}

      message ->
        %{"ok" => false, "output" => message, "emit" => []}
    end
  end
end
