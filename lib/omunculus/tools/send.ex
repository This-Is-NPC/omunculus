defmodule Omunculus.Tools.Send do
  @moduledoc """
  Builtin `send` tool, per spec §8.5: delivers a message, aimed at an
  existing work when `work_id` is given, or else at the `agent` of depth 0
  it names, as a `prompt` emit, with the `attachments` it carries.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.fetch(args, "message") do
      {:ok, message} ->
        body =
          %{"message" => message}
          |> Args.put_present("work_id", args)
          |> Args.put_present("agent", args)
          |> attachments(args)

        Out.ok("", [%{"type" => "prompt", "body" => body}])

      {:error, error} ->
        Out.fail(error)
    end
  end

  # The files the message carries, as `Omunculus.Attachments` kept them; the
  # store checks each.
  defp attachments(body, %{"attachments" => [_ | _] = list}),
    do: Map.put(body, "attachments", list)

  defp attachments(body, _args), do: body
end
