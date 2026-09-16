defmodule Omunculus.Tools.Write do
  @moduledoc """
  Builtin `write` tool, per spec §9.2: creates parent directories and
  writes `content` to `path` under the run's roots.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, roots: roots}) do
    case Args.missing(args, ~w(path content)) do
      nil -> write(roots, args["path"], args["content"])
      message -> Out.fail(message)
    end
  end

  defp write(roots, path, content) do
    case Omunculus.Tools.Path.resolve(roots, path) do
      {:ok, absolute} ->
        File.mkdir_p!(Path.dirname(absolute))
        File.write!(absolute, content)
        Out.ok()

      {:error, message} ->
        Out.fail(message)
    end
  end
end
