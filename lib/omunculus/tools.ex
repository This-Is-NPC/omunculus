defmodule Omunculus.Tools do
  @moduledoc false

  @catalog %{
    "read" => Omunculus.Tools.Read,
    "write" => Omunculus.Tools.Write,
    "edit" => Omunculus.Tools.Edit,
    "grep" => Omunculus.Tools.Grep,
    "find" => Omunculus.Tools.Find,
    "ls" => Omunculus.Tools.Ls,
    "counter" => Omunculus.Tools.Counter
  }

  def catalog, do: @catalog
  def names, do: Map.keys(@catalog)
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
