defmodule Omunculus.Tools do
  @moduledoc false

  @catalog %{
    "read" => Omunculus.Tools.Read,
    "write" => Omunculus.Tools.Write,
    "edit" => Omunculus.Tools.Edit,
    "grep" => Omunculus.Tools.Grep,
    "find" => Omunculus.Tools.Find,
    "ls" => Omunculus.Tools.Ls,
    "counter" => Omunculus.Tools.Counter,
    "delegate" => Omunculus.Tools.Delegate,
    "workspaces" => Omunculus.Tools.Workspaces
  }

  @groups %{
    "fs.read" => ["read", "grep", "find", "ls"],
    "fs.write" => ["edit", "write"]
  }

  def catalog, do: @catalog
  def groups, do: @groups
  def catalog_version, do: "1"
  def names, do: Map.keys(@catalog)

  def expand(name) when is_binary(name) do
    cond do
      Map.has_key?(@groups, name) -> {:ok, Map.fetch!(@groups, name)}
      Map.has_key?(@catalog, name) -> {:ok, [name]}
      true -> {:ok, [name]}
    end
  end

  def expand_list(names) when is_list(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case expand(name) do
        {:ok, expanded} -> {:cont, {:ok, acc ++ expanded}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.uniq(names)}
      {:error, _} = error -> error
    end
  end

  def default_names, do: ["read", "edit", "write", "grep", "find", "ls"]
  def get(name), do: Map.get(@catalog, name)

  def schemas(active) when is_list(active) do
    Enum.map(active, fn name ->
      mod = Map.fetch!(@catalog, name)
      Omunculus.Tool.openai_function(mod)
    end)
  end

  def call(name, args, fs, active) when is_list(active) do
    context = Omunculus.Tool.Context.new(fs)

    case call_context(name, args, context, active) do
      {:ok, output, context} -> {:ok, output, context.fs}
      {:error, reason, _context} -> {:error, reason}
    end
  end

  def call_context(name, args, context, active) when is_list(active) do
    cond do
      name not in active -> {:error, :denied, context}
      not Map.has_key?(@catalog, name) -> {:error, :denied, context}
      true -> Map.fetch!(@catalog, name).call(args || %{}, context)
    end
  end

  def validate_names(names) when is_list(names) do
    case Enum.find(names, &(!Map.has_key?(@catalog, &1))) do
      nil -> :ok
      name -> {:error, {:unknown_tool, name}}
    end
  end
end
