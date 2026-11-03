defmodule Omunculus.Tools.Merge do
  @moduledoc """
  Builtin `merge` tool: merges the branch `work/<id>` of a work handed
  down from the run's own, once it is done, into the run's root
  (`Omunculus.Worktree`). A conflict aborts the merge and fails the call,
  naming the conflicting paths. The root must be writable in the run.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.Out
  alias Omunculus.Worktree

  @spec run(map, Policy.t()) :: map
  def run(%{view: view, roots: [root | _]}, %Policy{} = policy) do
    with {:ok, id} <- child(view),
         :ok <- writable(policy, root) do
      case Worktree.merge(root, id) do
        {:ok, said} ->
          Out.ok(said)

        {:conflict, paths} ->
          Out.fail("conflict in: " <> Enum.join(paths, ", ") <> "; nothing merged")

        {:error, message} ->
          Out.fail(message)
      end
    else
      {:error, message} -> Out.fail(message)
    end
  end

  defp child(%{"own" => %{id: parent}, "target" => %{id: id, parent_id: parent, state: "done"}}),
    do: {:ok, id}

  defp child(%{"target" => %{}}),
    do: {:error, "work_id must name a done work handed down from this run's"}

  defp child(_view), do: {:error, "work_id must name a work below this run's"}

  defp writable(policy, root) do
    if Policy.writable?(policy, root), do: :ok, else: {:error, "the workspace is not writable"}
  end
end
