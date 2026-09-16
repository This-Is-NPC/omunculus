defmodule Omunculus.Tools.Grep do
  @moduledoc """
  Builtin `grep` tool, per spec §9.2: searches regular files under `path`
  for a regex pattern, recursively, skipping files that are not valid
  UTF-8.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.{Args, Out}

  @spec run(map, Policy.t()) :: map
  def run(%{args: args, roots: roots} = input, %Policy{} = policy) do
    permissions = Omunculus.Tools.Path.permissions(input)

    case Args.missing(args, ~w(pattern)) do
      nil ->
        search(roots, args["pattern"], Args.present(args, "path") || ".", permissions, policy)

      message ->
        Out.fail(message)
    end
  end

  defp search(roots, pattern, path, permissions, policy) do
    with {:ok, regex} <- compile(pattern),
         {:ok, absolute} <- Omunculus.Tools.Path.resolve(roots, path, permissions, policy) do
      output =
        absolute
        |> files()
        |> Enum.filter(
          &match?({:ok, _}, Omunculus.Tools.Path.resolve(roots, &1, permissions, policy))
        )
        |> Enum.sort()
        |> Enum.flat_map(&matches(&1, absolute, regex))
        |> Enum.join("\n")

      Out.ok(output)
    else
      {:error, message} -> Out.fail(message)
    end
  end

  defp compile(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, {message, _offset}} -> {:error, "invalid pattern: #{List.to_string(message)}"}
    end
  end

  defp files(absolute) do
    if File.regular?(absolute) do
      [absolute]
    else
      Path.join(absolute, "**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
    end
  end

  defp matches(file, base, regex) do
    with {:ok, content} <- File.read(file),
         true <- String.valid?(content) do
      relative = Path.relative_to(file, base)

      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> Regex.match?(regex, line) end)
      |> Enum.map(fn {line, n} -> "#{relative}:#{n}:#{line}" end)
    else
      _ -> []
    end
  end
end
