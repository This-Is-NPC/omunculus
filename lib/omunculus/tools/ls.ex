defmodule Omunculus.Tools.Ls do
  @moduledoc """
  Builtin `ls` tool, per spec §9.2: lists a directory under the run's
  roots, one entry per line, sorted, directories suffixed with `/`.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.{Args, Out}

  @spec run(map, Policy.t()) :: map
  def run(%{args: args, roots: roots} = input, %Policy{} = policy) do
    permissions = Omunculus.Tools.Path.permissions(input)
    path = Args.present(args, "path") || "."
    list(roots, path, permissions, policy)
  end

  defp list(roots, path, permissions, policy) do
    with {:ok, absolute} <- Omunculus.Tools.Path.resolve(roots, path, permissions, policy),
         {:ok, entries} <- File.ls(absolute) do
      output = entries |> Enum.sort() |> Enum.map(&entry(absolute, &1)) |> Enum.join("\n")
      Out.ok(output)
    else
      {:error, reason} when is_atom(reason) -> Out.fail("no such directory: #{path}")
      {:error, message} -> Out.fail(message)
    end
  end

  defp entry(dir, name) do
    if File.dir?(Path.join(dir, name)), do: name <> "/", else: name
  end
end
