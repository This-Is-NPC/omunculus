defmodule Omunculus.Tools.Read do
  @moduledoc """
  Builtin `read` tool, per spec §9.2: reads a file's contents from under
  the run's roots.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.{Args, Out}

  @spec run(map, Policy.t()) :: map
  def run(%{args: args, roots: roots} = input, %Policy{} = policy) do
    permissions = Omunculus.Tools.Path.permissions(input)

    case Args.missing(args, ~w(path)) do
      nil -> read(roots, args["path"], permissions, policy)
      message -> Out.fail(message)
    end
  end

  defp read(roots, path, permissions, policy) do
    with {:ok, absolute} <- Omunculus.Tools.Path.resolve(roots, path, permissions, policy),
         {:ok, content} <- File.read(absolute) do
      Out.ok(content)
    else
      {:error, reason} when is_atom(reason) -> Out.fail("no such file: #{path}")
      {:error, message} -> Out.fail(message)
    end
  end
end
