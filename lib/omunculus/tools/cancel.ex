defmodule Omunculus.Tools.Cancel do
  @moduledoc """
  Builtin `cancel` tool, a chain step of `reply`: emits `cancel` for the
  work of the request named by `request_id`.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.present(args, "request_id") do
      nil -> Out.fail("request_id required")
      request_id -> Out.ok("", [%{"type" => "cancel", "body" => %{"request_id" => request_id}}])
    end
  end
end
