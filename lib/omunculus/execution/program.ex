defmodule Omunculus.Execution.Program do
  @moduledoc """
  Resolves what an external process starts from to canonical paths. A
  program with a `/` in its name is a path; a bare name is looked up in each
  runtime's `bin`.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Path, as: FilesystemPath

  @doc "Whether `program` names a path rather than a runtime's program."
  @spec path?(String.t()) :: boolean
  def path?(program), do: String.contains?(program, "/")

  @doc "The first `<runtime>/bin/<program>` of `policy` that is a regular file."
  @spec runtime(String.t(), Policy.t()) :: {:ok, String.t()} | :error
  def runtime(program, %Policy{} = policy) do
    Enum.find_value(policy.runtimes, :error, fn runtime ->
      case file(Path.join([runtime, "bin", program])) do
        {:ok, _executable} = found -> found
        {:error, _reason} -> false
      end
    end)
  end

  @doc "The canonical `path`, refused unless it is a regular file."
  @spec file(String.t()) :: {:ok, String.t()} | {:error, :not_a_file | term}
  def file(path) do
    with {:ok, canonical} <- FilesystemPath.canonical(path),
         true <- File.regular?(canonical) do
      {:ok, canonical}
    else
      false -> {:error, :not_a_file}
      {:error, _reason} = error -> error
    end
  end

  @doc "The canonical `path`, refused unless it is a directory."
  @spec directory(String.t()) :: {:ok, String.t()} | {:error, :not_a_directory | term}
  def directory(path) do
    with {:ok, canonical} <- FilesystemPath.canonical(path),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      false -> {:error, :not_a_directory}
      {:error, _reason} = error -> error
    end
  end
end
