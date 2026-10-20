defmodule Omunculus.Tools.Write do
  @moduledoc """
  Builtin `write` tool: creates parent directories and
  writes `content` to `path` under the run's roots, whole or not at all.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.{Args, Out}

  @spec run(map, Policy.t()) :: map
  def run(%{args: args, roots: roots} = input, %Policy{} = policy) do
    permissions = Omunculus.Tools.Path.permissions(input)

    case Args.missing(args, ~w(path content)) do
      nil -> write(roots, args["path"], args["content"], permissions, policy)
      message -> Out.fail(message)
    end
  end

  defp write(roots, path, content, permissions, policy) do
    with {:ok, absolute} <- Omunculus.Tools.Path.resolve(roots, path, permissions, policy),
         :ok <- Omunculus.Tools.Path.writable(policy, absolute, path),
         :ok <- Omunculus.Tools.Path.write_atomic(absolute, content) do
      Out.ok()
    else
      {:error, message} -> Out.fail(message)
    end
  end
end
