defmodule Omunculus.Tools.Edit do
  @moduledoc """
  Builtin `edit` tool, per spec §9.2: replaces a single, exact occurrence
  of `old` with `new` in the file at `path`, under the run's roots.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.{Args, Out}

  @spec run(map, Policy.t()) :: map
  def run(%{args: args, roots: roots} = input, %Policy{} = policy) do
    permissions = Omunculus.Tools.Path.permissions(input)

    case Args.missing(args, ~w(path old new)) do
      nil -> edit(roots, args["path"], args["old"], args["new"], permissions, policy)
      message -> Out.fail(message)
    end
  end

  defp edit(roots, path, old, new, permissions, policy) do
    case Omunculus.Tools.Path.resolve(roots, path, permissions, policy) do
      {:ok, absolute} ->
        if Policy.writable?(policy, absolute) do
          case File.read(absolute) do
            {:ok, content} -> apply_edit(absolute, content, old, new)
            {:error, _reason} -> Out.fail("no such file: #{path}")
          end
        else
          Out.fail("path is not writable: #{path}")
        end

      {:error, message} ->
        Out.fail(message)
    end
  end

  defp apply_edit(absolute, content, old, new) do
    case content |> String.split(old) |> length() |> Kernel.-(1) do
      0 -> Out.fail("old text not found")
      1 -> write_edit(absolute, content, old, new)
      count -> Out.fail("old text is ambiguous: #{count} matches")
    end
  end

  defp write_edit(absolute, content, old, new) do
    File.write!(absolute, String.replace(content, old, new))
    Out.ok()
  end
end
