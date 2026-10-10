defmodule Omunculus.Tools.Changes do
  @moduledoc """
  Builtin `changes` tool: the files the calls of a work changed, as the
  harness recorded them with `[store] changes` — of the work `work_id`
  names below the run's own (the `target` view), or else of the run's own
  work (`own`) and this run so far (`run`). One line per call that changed
  files, each file with its operation and line counts; with `patch`, each
  call's unified diff instead.
  """

  alias Omunculus.{Changes, Config}
  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{args: args, view: view, config_path: config_path}) do
    with {:ok, %{store: %{changes: dir}}} when is_binary(dir) <- Config.load(config_path),
         {:ok, calls} <- calls(args, view) do
      render(calls, args["patch"] == true, dir)
    else
      {:ok, _config} -> Out.fail("changes are not recorded: [store] changes is not set")
      {:error, message} when is_binary(message) -> Out.fail(message)
      {:error, reason} -> Out.fail(Out.failure(reason))
    end
  end

  defp calls(%{"work_id" => _named}, %{"target" => work}) when is_map(work),
    do: {:ok, work_calls(work)}

  defp calls(%{"work_id" => _named}, _view),
    do: {:error, "work_id must name a work below this run's"}

  defp calls(_args, view),
    do: {:ok, work_calls(view["own"]) ++ changed(view["run"] || [], nil)}

  defp work_calls(nil), do: []
  defp work_calls(work), do: Enum.flat_map(work.runs, &changed(&1.events, &1.agent))

  defp changed(events, agent) do
    for %{type: "tool", body: body} <- events,
        %{"changes" => changes} = call <- [Jason.decode!(body)],
        do: %{agent: agent, name: call["name"], changes: changes}
  end

  defp render([], _patch, _dir), do: Out.ok("No call changed a file.")

  defp render(calls, false, _dir), do: Out.ok(Enum.map_join(calls, "\n", &summary/1))

  defp render(calls, true, dir) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      case Changes.patch(dir, call.changes["before"], call.changes["after"]) do
        {:ok, patch} -> {:cont, {:ok, acc ++ [heading(call) <> "\n" <> patch]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> Out.ok(Enum.join(parts, "\n"))
      {:error, reason} -> Out.fail(Out.failure(reason))
    end
  end

  defp summary(call) do
    heading(call) <>
      Enum.map_join(call.changes["files"], "", fn file ->
        "\n  #{file["op"]} #{file["path"]}#{lines(file)}"
      end)
  end

  defp heading(%{agent: nil, name: name}), do: "- #{name} (this run)"
  defp heading(%{agent: agent, name: name}), do: "- #{name} (#{agent})"

  defp lines(%{"added" => nil}), do: " (binary)"
  defp lines(%{"added" => added, "deleted" => deleted}), do: " (+#{added} -#{deleted})"
end
