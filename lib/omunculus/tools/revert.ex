defmodule Omunculus.Tools.Revert do
  @moduledoc """
  Builtin `revert` tool: puts the files the calls of a work changed back
  as they were before its first change to each, from what `[store]
  changes` kept — of the work `work_id` names below the run's own, or of
  the run's own work and this run so far (the views of `changes`). A
  file the work added is removed. When any of them changed after the
  work's last change to it, by another run, a command or a person, it
  restores nothing and names them. Each file must be writable in the run.
  """

  alias Omunculus.{Changes, Config}
  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.Out

  @spec run(map, Policy.t()) :: map
  def run(
        %{args: args, view: view, config_path: config_path, roots: [root | _]},
        %Policy{} = policy
      ) do
    with {:ok, %{store: %{changes: dir}}} when is_binary(dir) <- Config.load(config_path),
         {:ok, calls} <- Omunculus.Tools.Changes.calls(args, view),
         files = span(calls),
         :ok <- writable(policy, root, files),
         {:ok, plan} <- plan(dir, root, files),
         :ok <- restore(dir, root, plan) do
      Out.ok(summary(plan))
    else
      {:ok, _config} -> Out.fail("changes are not recorded: [store] changes is not set")
      {:error, message} when is_binary(message) -> Out.fail(message)
      {:error, reason} -> Out.fail(Out.failure(reason))
    end
  end

  # Each file the calls changed: the tree before its first change and the
  # tree after its last.
  defp span(calls) do
    calls
    |> Enum.flat_map(fn %{changes: changes} ->
      for file <- changes["files"], do: {file["path"], changes["before"], changes["after"]}
    end)
    |> Enum.reduce(%{}, fn {path, before, after_}, acc ->
      Map.update(acc, path, {before, after_}, fn {first, _last} -> {first, after_} end)
    end)
    |> Enum.sort()
  end

  defp writable(policy, root, files) do
    Enum.find_value(files, :ok, fn {path, _trees} ->
      case Omunculus.Tools.Path.writable(policy, Path.join(root, path), path) do
        :ok -> nil
        error -> error
      end
    end)
  end

  # What each file goes back to, once every one is as the work left it.
  defp plan(dir, root, files) do
    files
    |> Enum.reduce_while({:ok, [], []}, fn {path, {before, after_}}, {:ok, plan, moved} ->
      with {:ok, left} <- Changes.object(dir, after_, path),
           {:ok, now} <- Changes.hash(dir, Path.join(root, path)),
           {:ok, was} <- Changes.object(dir, before, path) do
        if left == now,
          do: {:cont, {:ok, plan ++ [{path, was}], moved}},
          else: {:cont, {:ok, plan, moved ++ [path]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, [], []} ->
        {:error, "No call changed a file."}

      {:ok, plan, []} ->
        {:ok, plan}

      {:ok, _plan, moved} ->
        {:error,
         "refused: #{Enum.join(moved, ", ")} changed after the work's last change; nothing was restored"}

      error ->
        error
    end
  end

  defp restore(dir, root, plan) do
    Enum.reduce_while(plan, :ok, fn {path, was}, :ok ->
      absolute = Path.join(root, path)

      result =
        case was do
          nil ->
            File.rm(absolute)

          object ->
            with {:ok, content} <- Changes.content(dir, object),
                 do: Omunculus.Tools.Path.write_atomic(absolute, content)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp summary(plan) do
    {removed, restored} = Enum.split_with(plan, fn {_path, was} -> is_nil(was) end)

    [
      {"Restored", restored},
      {"Removed", removed}
    ]
    |> Enum.reject(fn {_label, files} -> files == [] end)
    |> Enum.map_join("\n", fn {label, files} ->
      "#{label}: " <> Enum.map_join(files, ", ", &elem(&1, 0))
    end)
  end
end
