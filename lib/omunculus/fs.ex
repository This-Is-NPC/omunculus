defmodule Omunculus.FS do
  @moduledoc false

  @type t :: %{
          optional(:mod) => module(),
          optional(:cwd) => String.t(),
          optional(:files) => map(),
          optional(atom()) => term()
        }

  @callback cwd(t()) :: String.t()
  @callback read_file(t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback write_file(t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  @callback list_dir(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback walk_files(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}

  def cwd(%{mod: mod} = fs), do: mod.cwd(fs)
  def read_file(%{mod: mod} = fs, path, opts \\ %{}), do: mod.read_file(fs, path, opts)
  def write_file(%{mod: mod} = fs, path, content), do: mod.write_file(fs, path, content)
  def list_dir(%{mod: mod} = fs, path), do: mod.list_dir(fs, path)
  def walk_files(%{mod: mod} = fs, path), do: mod.walk_files(fs, path)
end
