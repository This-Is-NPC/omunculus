defmodule Omunculus.Tools.Reply do
  @moduledoc """
  Builtin `reply` tool: answers a `request` with a comment body and
  optionally one of its options. A null or empty option is omitted.
  A text-only answer chains no calls. Emits
  `reply` and chains the chosen option's tool calls
  from the `request` view, each with the request's `request_id` in its
  args. An option the request does not have chains nothing; the store
  refuses the `reply`. Triggered from both the CLI and a model.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(request_id body)

  @spec run(map) :: map
  def run(%{args: args, view: view}) do
    args = if args["option"] in [nil, ""], do: Map.delete(args, "option"), else: args

    case Args.missing(args, @required) do
      nil ->
        Out.ok("", [%{"type" => "reply", "body" => Map.take(args, ["option" | @required])}])
        |> Map.put("chain", option_calls(view["request"], args))

      message ->
        Out.fail(message)
    end
  end

  defp option_calls(nil, _args), do: []

  defp option_calls(request, %{"request_id" => request_id} = args) do
    option = Map.get(args, "option")

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
