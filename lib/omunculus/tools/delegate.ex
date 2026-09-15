defmodule Omunculus.Tools.Delegate do
  @moduledoc """
  Builtin `delegate` tool, per spec §3.4: creates a child work and hands it
  to whoever is below. The parent waits.
  """

  alias Omunculus.Tools.Args

  @required ~w(title body)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil ->
        body = %{"title" => args["title"], "body" => args["body"]}
        %{"ok" => true, "output" => "", "emit" => [%{"type" => "delegate", "body" => body}]}

      message ->
        %{"ok" => false, "output" => message, "emit" => []}
    end
  end
end
