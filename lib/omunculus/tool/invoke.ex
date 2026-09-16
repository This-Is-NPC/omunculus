defmodule Omunculus.Tool.Invoke do
  @moduledoc """
  Runs a tool or hook's contract per spec §8.1 and §8.7: JSON `in` on
  stdin, JSON `out` on stdout for a `command`; a `tools/call` to the MCP
  server for a manifest with `mcp` set. Either way the result goes through
  the same `validate/1`.
  """

  alias Omunculus.Execution
  alias Omunculus.Execution.{Command, Policy}
  alias Omunculus.Mcp
  alias Omunculus.Path, as: FilesystemPath
  alias Omunculus.Tool.Manifest

  @runner ~s(exec "$@")

  @spec call(Manifest.t(), map) ::
          {:ok, %{ok: boolean, output: String.t(), emit: [map]}} | {:error, term}
  def call(manifest, input), do: call(manifest, input, nil)

  @spec call(Manifest.t(), map, Policy.t() | nil) ::
          {:ok, %{ok: boolean, output: String.t(), emit: [map]}} | {:error, term}
  def call(%Manifest{mcp: mcp} = manifest, input, _execution) when not is_nil(mcp) do
    with {:ok, result} <- Mcp.call(mcp, manifest.name, input.args) do
      validate(%{"ok" => result.ok, "output" => result.output, "emit" => result.emit})
    end
  end

  def call(%Manifest{module: module}, input, execution) when is_binary(module) do
    with {:ok, mod} <- resolve_module(module) do
      case run_module(mod, input, execution) do
        {:error, _reason} = error -> error
        decoded -> validate(decoded)
      end
    end
  end

  def call(%Manifest{command: command} = manifest, input, %Policy{} = execution)
      when is_list(command) do
    with {:ok, command} <- external_command(manifest, command, execution) do
      case Execution.run(command, execution, Jason.encode!(input)) do
        {:ok, %{stdout: stdout}} -> decode(stdout)
        {:error, {:exit, status, _stdout, stderr}} -> {:error, {:exit, status, stderr}}
        {:error, _reason} = error -> error
      end
    end
  end

  def call(%Manifest{command: command}, _input, nil) when is_list(command),
    do: {:error, :execution_context_required}

  defp run_module(module, input, %Policy{} = execution) do
    if function_exported?(module, :run, 2),
      do: module.run(input, execution),
      else: module.run(input)
  end

  defp run_module(module, input, nil) do
    if function_exported?(module, :run, 1),
      do: module.run(input),
      else: {:error, :execution_context_required}
  end

  defp resolve_module(module) do
    atom = String.to_existing_atom("Elixir." <> module)

    if Code.ensure_loaded?(atom) and
         (function_exported?(atom, :run, 1) or function_exported?(atom, :run, 2)) do
      {:ok, atom}
    else
      {:error, {:no_module, module}}
    end
  rescue
    ArgumentError -> {:error, {:no_module, module}}
  end

  defp external_command(%Manifest{dir: dir}, [program | args], policy) do
    with {:ok, executable} <- executable(dir, program, policy),
         {:ok, command} <-
           Command.new(
             "/usr/bin/sh",
             ["-c", @runner, "omunculus-tool", executable | args],
             cwd: dir
           ) do
      {:ok, command}
    end
  end

  defp executable(dir, program, policy) do
    if Path.type(program) == :absolute or String.contains?(program, "/") do
      tool_executable(dir, Path.expand(program, dir))
    else
      runtime_executable(program, policy)
    end
  end

  defp tool_executable(dir, path) do
    with {:ok, root} <- canonical_directory(dir),
         {:ok, executable} <- canonical_file(path),
         true <- FilesystemPath.within?(root, executable) do
      {:ok, executable}
    else
      false -> {:error, :command_outside_policy}
      {:error, _reason} = error -> error
    end
  end

  defp runtime_executable(program, policy) do
    policy.runtimes
    |> Enum.map(&Path.join([&1, "bin", program]))
    |> Enum.find_value({:error, :command_not_found}, fn path ->
      case canonical_file(path) do
        {:ok, executable} -> {:ok, executable}
        {:error, _reason} -> false
      end
    end)
  end

  defp canonical_directory(path) do
    with {:ok, canonical} <- FilesystemPath.canonical(path),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      false -> {:error, :command_directory}
      {:error, reason} -> {:error, {:command_directory, reason}}
    end
  end

  defp canonical_file(path) do
    with {:ok, canonical} <- FilesystemPath.canonical(path),
         true <- File.regular?(canonical) do
      {:ok, canonical}
    else
      false -> {:error, :command_not_found}
      {:error, reason} -> {:error, {:command, reason}}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> validate(decoded)
      {:error, _reason} -> {:error, {:invalid_output, raw}}
    end
  end

  defp validate(decoded) when is_map(decoded) do
    with {:ok, ok} <- fetch_bool(decoded, "ok"),
         {:ok, output} <- fetch_string(decoded, "output", ""),
         {:ok, emit} <- fetch_emit(decoded) do
      {:ok, %{ok: ok, output: output, emit: emit}}
    end
  end

  defp validate(decoded), do: {:error, {:invalid_output, decoded}}

  defp fetch_bool(decoded, key) do
    case Map.fetch(decoded, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_output, decoded}}
    end
  end

  defp fetch_string(decoded, key, default) do
    case Map.fetch(decoded, key) do
      :error -> {:ok, default}
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_output, decoded}}
    end
  end

  defp fetch_emit(decoded) do
    case Map.fetch(decoded, "emit") do
      :error ->
        {:ok, []}

      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &valid_emit_entry?/1),
          do: {:ok, list},
          else: {:error, {:invalid_output, decoded}}

      _ ->
        {:error, {:invalid_output, decoded}}
    end
  end

  defp valid_emit_entry?(%{"type" => type, "body" => body}),
    do: is_binary(type) and is_map(body)

  defp valid_emit_entry?(_), do: false
end
