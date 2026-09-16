defmodule Omunculus.Tools.Write do
  @moduledoc """
  Builtin `write` tool, per spec §9.2: creates parent directories and
  writes `content` to `path` under the run's roots.
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
    case Omunculus.Tools.Path.resolve(roots, path, permissions, policy) do
      {:ok, absolute} ->
        if Policy.writable?(policy, absolute) do
          File.mkdir_p!(Path.dirname(absolute))
          File.write!(absolute, content)
          Out.ok()
        else
          Out.fail("path is not writable: #{path}")
        end

      {:error, message} ->
        Out.fail(message)
    end
  end
end
