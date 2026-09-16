defmodule Omunculus.Tool.Invoke do
  @moduledoc """
  Runs a tool or hook's contract per spec §8.1 and §8.7: JSON `in` on
  stdin, JSON `out` on stdout for a `command`; a `tools/call` to the MCP
  server for a manifest with `mcp` set. Either way the result goes through
  the same `validate/1`.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Mcp
  alias Omunculus.Tool.Manifest

  @stdin_script ~s(exec "$@" < "$0")

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

  def call(%Manifest{command: command} = manifest, input, _execution) when is_list(command) do
    tmp_path = Path.join(System.tmp_dir!(), Omunculus.Id.new())

    try do
      File.write!(tmp_path, Jason.encode!(input))

      System.cmd("sh", ["-c", @stdin_script, tmp_path | manifest.command],
        cd: manifest.dir,
        stderr_to_stdout: false
      )
      |> handle_result()
    after
      File.rm(tmp_path)
    end
  end

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

  defp handle_result({output, 0}), do: decode(output)
  defp handle_result({output, status}), do: {:error, {:exit, status, output}}

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
