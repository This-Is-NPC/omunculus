defmodule Omunculus.Tools.Forget do
  @moduledoc "Builtin `forget` tool: emits a `memory` action that ends the entry `id`."

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.fetch(args, "id") do
      {:ok, id} ->
        Out.ok("forgot #{id}", [%{"type" => "memory", "body" => %{"op" => "forget", "id" => id}}])

      {:error, message} ->
        Out.fail(message)
    end
  end
end
