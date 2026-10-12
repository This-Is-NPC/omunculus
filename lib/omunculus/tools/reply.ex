defmodule Omunculus.Tools.Reply do
  @moduledoc """
  Builtin `reply` tool: answers a `request` with a comment body and
  optionally one of its options. A null or empty option is omitted.
  Named parts select calls on their original requests recursively.
  A text-only answer chains no calls. Emits
  `reply` and chains the chosen option's tool calls
  from the `request` view, each with the request's `request_id` in its
  args. Invalid or closed replies chain no calls and are refused by the store. Triggered from both the CLI and a model.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(request_id body)

  @spec run(map) :: map
  def run(%{args: args, view: view} = input) do
    with nil <- Args.missing(args, @required),
         {:ok, parts} <- Args.object(args, "parts") do
      args =
        normalize(if Map.has_key?(args, "parts"), do: Map.put(args, "parts", parts), else: args)

      with :ok <- Omunculus.RequestOptions.authorize(view["request"], args, is_nil(input.run_id)) do
        calls =
          case Omunculus.RequestOptions.validate(view["request"], args) do
            :ok -> option_calls(view["request"], args)
            {:error, _reason} -> []
          end

        Out.ok("", [
          %{"type" => "reply", "body" => Map.take(args, ["parts", "option" | @required])}
        ])
        |> Map.put("chain", calls)
      else
        {:error, reason} ->
          Out.fail(Out.refused(reason))
      end
    else
      {:error, message} -> Out.fail(message)
      message -> Out.fail(message)
    end
  end

  defp normalize(answer) when is_map(answer) do
    answer = if answer["option"] in [nil, ""], do: Map.delete(answer, "option"), else: answer

    if is_map(answer["parts"]),
      do:
        Map.update!(
          answer,
          "parts",
          &Map.new(&1, fn {part, value} -> {part, normalize(value)} end)
        ),
      else: answer
  end

  defp normalize(answer), do: answer

  defp option_calls(nil, _args), do: []

  defp option_calls(request, %{"request_id" => request_id} = args) do
    option = Map.get(args, "option")

    own =
      request.options
      |> Jason.decode!()
      |> Map.get(option, [])
      |> Enum.map(
        &Map.update(&1, "args", %{"request_id" => request_id}, fn args ->
          Map.put(args, "request_id", request_id)
        end)
      )

    own ++
      for {part, answer} <- Map.get(args, "parts", %{}),
          is_map(answer),
          origin = Map.get(Map.get(request, :origins, %{}), part),
          not is_nil(origin),
          call <- option_calls(origin, Map.put(answer, "request_id", origin.id)),
          do: call
  end
end
