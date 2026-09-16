defmodule Omunculus.Tools.Find do
  @moduledoc """
  Builtin `find` tool, per spec §9.2: matches `pattern` as a wildcard
  under `path`, dropping results that escape the run's roots.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, roots: roots} = input) do
    permissions = Omunculus.Tools.Path.permissions(input)

    case Args.missing(args, ~w(pattern)) do
      nil -> search(roots, args["pattern"], Args.present(args, "path") || ".", permissions)
      message -> Out.fail(message)
    end
  end

  defp search(roots, pattern, path, permissions) do
    case Omunculus.Tools.Path.resolve(roots, path, permissions) do
      {:ok, absolute} ->
        output =
          absolute
          |> Path.join(pattern)
          |> Path.wildcard(match_dot: true)
          |> Enum.filter(&inside_roots?(roots, &1, permissions))
          |> Enum.map(&Path.relative_to(&1, absolute))
          |> Enum.sort()
          |> Enum.join("\n")

        Out.ok(output)

      {:error, message} ->
        Out.fail(message)
    end
  end

  defp inside_roots?(roots, match, permissions) do
    match?({:ok, _}, Omunculus.Tools.Path.resolve(roots, match, permissions))
  end
end
