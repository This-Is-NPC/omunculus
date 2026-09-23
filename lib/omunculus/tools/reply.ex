defmodule Omunculus.Tools.Reply do
  @moduledoc """
  Builtin `reply` tool: answers a `request` with one of its options and a
  comment body. Emits `reply` and chains the chosen option's tool calls
  from the `request` view, each with the request's `request_id` in its
  args. An option the request does not have chains nothing; the store
  refuses the `reply`. Triggered from both the CLI and a model.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(request_id option body)

  @spec run(map) :: map
  def run(%{args: args, view: view}) do
    case Args.missing(args, @required) do
      nil ->
        Out.ok("", [%{"type" => "reply", "body" => Map.take(args, @required)}])
        |> Map.put("chain", option_calls(view["request"], args))

      message ->
        Out.fail(message)
    end
  end

  defp option_calls(nil, _args), do: []

  defp option_calls(request, %{"request_id" => request_id, "option" => option}) do
    request.options
    |> Jason.decode!()
    |> Map.get(option, [])
    |> Enum.map(
      &Map.update(&1, "args", %{"request_id" => request_id}, fn args ->
        Map.put(args, "request_id", request_id)
      end)
    )
  end
end
