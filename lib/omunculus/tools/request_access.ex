defmodule Omunculus.Tools.RequestAccess do
  @moduledoc """
  Builtin `request_access` tool, per spec §3.5: emits a `request` for a
  `kind`/`name` with a `reason`; the store classifies the name against the
  run's ceiling and decides whether it opens a `REQUESTS` row.
  """

  alias Omunculus.Tools.Args

  @required ~w(kind name reason)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil ->
        body = %{"kind" => args["kind"], "name" => args["name"], "reason" => args["reason"]}
        %{"ok" => true, "output" => "", "emit" => [%{"type" => "request", "body" => body}]}

      message ->
        %{"ok" => false, "output" => message, "emit" => []}
    end
  end
end
