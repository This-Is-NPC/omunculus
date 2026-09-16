defmodule Omunculus.Tools.CompactComments do
  @moduledoc """
  Builtin `compact_comments` tool, per spec §8.2: composite tool that loads
  the `comments.work` view for the model to summarize, then commits the
  summary as a `compact` emit.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: %{"op" => "load"}, view: view}) do
    output =
      case Map.get(view, "comments.work", []) do
        [] -> "sem comments"
        comments -> comments |> Enum.map(&line/1) |> Enum.join("\n")
      end

    Out.ok(output)
  end

  def run(%{args: %{"op" => "commit"} = args} = input) do
    case Args.missing(args, ["summary"]) do
      nil -> commit(input, args)
      message -> Out.fail(message)
    end
  end

  def run(_input) do
    Out.fail("op must be load or commit")
  end

  defp commit(%{work_id: nil}, _args), do: Out.fail("no work to compact")

  defp commit(%{work_id: work_id}, args) do
    body =
      %{"work_id" => work_id, "summary" => Args.present(args, "summary")}
      |> put_ids(args)

    Out.ok("", [%{"type" => "compact", "body" => body}])
  end

  defp put_ids(body, args) do
    case Map.get(args, "ids") do
      [_ | _] = ids -> Map.put(body, "ids", ids)
      _ -> body
    end
  end

  defp line(%{id: id, author: author, body: body}), do: "#{id} #{author}: #{body}"
end
