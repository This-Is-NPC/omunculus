defmodule Omunculus.Tools.Find do
  @moduledoc """
  Builtin `find` tool: matches `pattern` as a wildcard
  under `path`, dropping results that escape the run's roots and what
  `Omunculus.Tools.Ignore` leaves out. With `limit`, it keeps that many
  paths and a last line says how many more there are.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.{Args, Out}

  @spec run(map, Policy.t()) :: map
  def run(%{args: args, roots: roots} = input, %Policy{} = policy) do
    permissions = Omunculus.Tools.Path.permissions(input)

    with nil <- Args.missing(args, ~w(pattern)),
         {:ok, limit} <- Args.count(args, "limit") do
      path = Args.present(args, "path") || "."
      search(roots, args["pattern"], path, limit, permissions, policy)
    else
      {:error, message} -> Out.fail(message)
      message -> Out.fail(message)
    end
  end

  defp search(roots, pattern, path, limit, permissions, policy) do
    case Omunculus.Tools.Path.resolve(roots, path, permissions, policy) do
      {:ok, absolute} ->
        absolute
        |> Path.join(pattern)
        |> Path.wildcard(match_dot: true)
        |> Omunculus.Tools.Ignore.reject(absolute)
        |> Enum.filter(&inside_roots?(roots, &1, permissions, policy))
        |> Enum.map(&Path.relative_to(&1, absolute))
        |> Enum.sort()
        |> Out.listed(limit)
        |> Out.ok()

      {:error, message} ->
        Out.fail(message)
    end
  end

  defp inside_roots?(roots, match, permissions, policy) do
    match?({:ok, _}, Omunculus.Tools.Path.resolve(roots, match, permissions, policy))
  end
end
