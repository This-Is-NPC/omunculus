defmodule Omunculus.Tools.Edit do
  @moduledoc """
  Builtin `edit` tool, per spec §9.2: replaces a single, exact occurrence
  of `old` with `new` in the file at `path`, under the run's roots.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, roots: roots}) do
    case Args.missing(args, ~w(path old new)) do
      nil -> edit(roots, args["path"], args["old"], args["new"])
      message -> Out.fail(message)
    end
  end

  defp edit(roots, path, old, new) do
    with {:ok, absolute} <- Omunculus.Tools.Path.resolve(roots, path),
         {:ok, content} <- File.read(absolute) do
      apply_edit(absolute, content, old, new)
    else
      {:error, reason} when is_atom(reason) -> Out.fail("no such file: #{path}")
      {:error, message} -> Out.fail(message)
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
