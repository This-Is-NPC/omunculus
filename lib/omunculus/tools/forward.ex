defmodule Omunculus.Tools.Forward do
  @moduledoc """
  Builtin `forward` tool: emits a `prompt` with `message` for `work_id`, a
  root work of the run's conversation (its `works` view) still open or
  waiting, which opens a run of that work. Its manifest's `then` appends
  `end`.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, view: view}) do
    with nil <- Args.missing(args, ~w(work_id message)),
         :ok <- open(Map.get(view, "works") || [], args["work_id"]) do
      Out.ok("", [
        %{
          "type" => "prompt",
          "body" => %{"work_id" => args["work_id"], "message" => args["message"]}
        }
      ])
    else
      {:error, message} -> Out.fail(message)
      message -> Out.fail(message)
    end
  end

  defp open(works, id) do
    case Enum.find(works, &(&1.id == id)) do
      nil ->
        {:error, "no work #{id} under ## Works"}

      %{state: state} when state in ["open", "waiting"] ->
        :ok

      %{state: state} ->
        {:error,
         "work #{id} is #{state} and takes no more messages: create a new work that names it"}
    end
  end
end
