defmodule Omunculus.Tools.Read do
  @moduledoc """
  Builtin `read` tool, per spec §9.2: reads a file's contents from under
  the run's roots.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, roots: roots}) do
    case Args.missing(args, ~w(path)) do
      nil -> read(roots, args["path"])
      message -> Out.fail(message)
    end
  end

  defp read(roots, path) do
    with {:ok, absolute} <- Omunculus.Tools.Path.resolve(roots, path),
         {:ok, content} <- File.read(absolute) do
      Out.ok(content)
    else
      {:error, reason} when is_atom(reason) -> Out.fail("no such file: #{path}")
      {:error, message} -> Out.fail(message)
    end
  end
end
