defmodule Omunculus.Tools.Work do
  @moduledoc """
  Builtin `work` tool: takes a `report` and the `works` to create, each
  with a `title`, a `goal` and optionally an `agent` and a `workspace`.
  In a run with a work it chains `comment` with the report on that work
  and one `delegate` per item. In a run without a work it takes exactly
  one item and emits the `work` action, which creates the root work with
  the report as its first comment. Its manifest's `then` appends `end`.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(title goal)
  @optional ~w(agent workspace)

  @spec run(map) :: map
  def run(%{args: args, work_id: work_id}) do
    with {:ok, report} <- Args.fetch(args, "report"),
         {:ok, works} <- works(args["works"]) do
      create(work_id, report, works)
    else
      {:error, message} -> Out.fail(message)
    end
  end

  defp works([_ | _] = items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case item(item) do
        {:ok, work} -> {:cont, {:ok, acc ++ [work]}}
        {:error, message} -> {:halt, {:error, "works[#{index}]: #{message}"}}
      end
    end)
  end

  defp works(_items), do: {:error, "works required"}

  defp item(item) when is_map(item) do
    case Args.missing(item, @required) do
      nil ->
        {:ok, Enum.reduce(@required ++ @optional, %{}, &Args.put_present(&2, &1, item))}

      message ->
        {:error, message}
    end
  end

  defp item(_item), do: {:error, "object required"}

  defp create(nil, report, [work]),
    do: Out.ok("", [%{"type" => "work", "body" => Map.put(work, "report", report)}])

  defp create(nil, _report, _works), do: Out.fail("a run without a work creates one work")

  defp create(_work_id, report, works) do
    Out.ok("")
    |> Map.put(
      "chain",
      [%{"name" => "comment", "args" => %{"body" => report}}] ++
        Enum.map(works, &%{"name" => "delegate", "args" => &1})
    )
  end
end
