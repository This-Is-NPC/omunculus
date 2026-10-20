defmodule Omunculus.Tools.Reopen do
  @moduledoc """
  Builtin `reopen` tool: emits `reopen` for `work_id`, a work below the
  run's own that broke, with `instructions` on how to go on, which reopens
  it, comments them on it and runs its agent again, the `agent` it names
  at that depth, or, in a workflow, the agent of the `stage` it names,
  giving it on that work what `grant` lists, each a `{kind, name}`, and
  with `past_limit`, the question the store asks the parent's route
  instead once the work went back `[policy] max_reopens` times in a row.
  Its manifest's `then` appends `end`.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args}) do
    with {:ok, work_id} <- Args.fetch(args, "work_id"),
         {:ok, instructions} <- Args.fetch(args, "instructions"),
         {:ok, body} <-
           %{
             "work_id" => work_id,
             "body" => instructions,
             "past_limit" => Out.reopen_limit(work_id, instructions)
           }
           |> Args.put_present("agent", args)
           |> Args.put_present("stage", args)
           |> put_grant(args["grant"]) do
      Out.ok("", [%{"type" => "reopen", "body" => body}])
    else
      {:error, message} -> Out.fail(message)
    end
  end

  defp put_grant(body, nil), do: {:ok, body}
  defp put_grant(body, []), do: {:ok, body}

  defp put_grant(body, grant) when is_list(grant) do
    if Enum.all?(grant, &named?/1),
      do: {:ok, Map.put(body, "grant", Enum.map(grant, &Map.take(&1, ~w(kind name))))},
      else: {:error, "each grant needs a kind and a name"}
  end

  defp put_grant(_body, _grant), do: {:error, "grant must be a list of {kind, name}"}

  defp named?(%{"kind" => kind, "name" => name}),
    do: kind in ~w(tool resource path directory) and is_binary(name) and name != ""

  defp named?(_grant), do: false
end
