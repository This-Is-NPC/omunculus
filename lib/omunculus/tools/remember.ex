defmodule Omunculus.Tools.Remember do
  @moduledoc """
  Builtin `remember` tool: emits a `memory` action keeping a lesson or
  fact beyond the conversation, in a `scope` and of a `kind`. The same
  text already kept in that scope and kind, in the `memories` view, is not
  kept twice.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, view: view}) do
    with nil <- Args.missing(args, ~w(scope kind text)) do
      text = String.trim(args["text"])

      case Enum.find(view["memories"] || [], &same?(&1, args, text)) do
        %{"id" => id} ->
          Out.ok("already remembered as #{id}")

        nil ->
          body = %{
            "op" => "remember",
            "scope" => args["scope"],
            "kind" => args["kind"],
            "text" => text
          }

          Out.ok("remembered", [%{"type" => "memory", "body" => body}])
      end
    else
      message -> Out.fail(message)
    end
  end

  defp same?(entry, args, text) do
    entry["scope"] == args["scope"] and entry["kind"] == args["kind"] and
      String.downcase(entry["text"]) == String.downcase(text)
  end
end
