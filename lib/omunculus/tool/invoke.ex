defmodule Omunculus.Tool.Invoke do
  @moduledoc """
  Runs a tool or hook's contract: JSON `in` on
  stdin, JSON `out` on stdout for a `command`; a `tools/call` to the MCP
  server for a manifest with `mcp` set. Either way the result goes through
  the same `validate/1`. The optional `chain` of `out` is a list of
  `{name, args}` steps; `args` defaults to an empty map. The optional
  `instructions` of `out`, empty by default, is the part of a prompt the
  tool assembles that stays the same from run to run, and its optional
  `session` the session the run continues (`Omunculus.Tools.Session`).
  Its optional `media` lists the images and PDFs to show the model
  (`Omunculus.Media`). An `output` that is not valid UTF-8 has its invalid bytes replaced, so
  what a tool printed can always be recorded and sent to a model.
  """

  alias Omunculus.Execution
  alias Omunculus.Execution.{Command, Policy, Program}
  alias Omunculus.Mcp
  alias Omunculus.Path, as: FilesystemPath
  alias Omunculus.Tool.{Manifest, Resident}

  @type out :: %{
          ok: boolean,
          output: String.t(),
          emit: [map],
          media: [map],
          chain: [%{name: String.t(), args: map}],
          instructions: String.t(),
          session: map | nil
        }

  @spec call(Manifest.t(), map) :: {:ok, out} | {:error, term}
  def call(manifest, input), do: call(manifest, input, nil)

  @doc """
  Calls the tool `manifest` with `input`. A `command` tool or an MCP
  server runs under `execution`, and its process alone receives `secrets`.
  """
  @spec call(Manifest.t(), map, Policy.t() | nil, %{String.t() => String.t()}) ::
          {:ok, out} | {:error, term}
  def call(manifest, input, execution, secrets \\ %{})

  def call(%Manifest{mcp: mcp} = manifest, input, %Policy{} = execution, secrets)
      when not is_nil(mcp) do
    with {:ok, result} <- Mcp.call(mcp, manifest.name, input.args, execution, secrets) do
      validate(%{"ok" => result.ok, "output" => result.output, "emit" => result.emit})
    end
  end

  def call(%Manifest{mcp: mcp}, _input, nil, _secrets) when not is_nil(mcp),
    do: {:error, :execution_context_required}

  def call(%Manifest{module: module}, input, execution, _secrets) when is_binary(module) do
    with {:ok, mod} <- resolve_module(module) do
      case run_module(mod, input, execution) do
        {:error, _reason} = error -> error
        decoded -> validate(decoded)
      end
    end
  end

  def call(%Manifest{command: command} = manifest, input, %Policy{} = execution, secrets)
      when is_list(command) do
    with {:ok, command} <- external_command(manifest, command, execution, secrets) do
      case run_command(manifest, command, input, execution) do
        {:ok, stdout} -> decode(stdout)
        {:error, {:exit, status, _stdout, stderr}} -> {:error, {:exit, status, stderr}}
        {:error, _reason} = error -> error
      end
    end
  end

  def call(%Manifest{command: command}, _input, nil, _secrets) when is_list(command),
    do: {:error, :execution_context_required}

  # A tool that keeps alive has its process of the run take the call as one
  # line; outside a run, or without the option, a process serves one call.
  defp run_command(
         %Manifest{keep_alive_ms: ms} = manifest,
         command,
         %{run_id: run_id} = input,
         execution
       )
       when is_integer(ms) and is_binary(run_id) do
    Resident.call({run_id, manifest.name}, command, Jason.encode!(input), execution,
      keep_alive_ms: ms
    )
  end

  defp run_command(_manifest, command, input, execution) do
    with {:ok, %{stdout: stdout}} <- Execution.run(command, execution, Jason.encode!(input)),
         do: {:ok, stdout}
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

  defp external_command(%Manifest{dir: dir}, [program | args], policy, secrets) do
    with {:ok, executable} <- executable(dir, program, policy),
         {:ok, command} <-
           Command.new(
             "/usr/bin/sh",
             ["-c", policy.sandbox.exec, "omunculus-tool", executable | args],
             cwd: dir,
             secrets: secrets
           ) do
      {:ok, command}
    end
  end

  defp executable(dir, program, policy) do
    if Program.path?(program) do
      tool_executable(dir, Path.expand(program, dir))
    else
      with :error <- Program.runtime(program, policy), do: {:error, :command_not_found}
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

  defp canonical_directory(path) do
    case Program.directory(path) do
      {:ok, _root} = found -> found
      {:error, :not_a_directory} -> {:error, :command_directory}
      {:error, reason} -> {:error, {:command_directory, reason}}
    end
  end

  defp canonical_file(path) do
    case Program.file(path) do
      {:ok, _executable} = found -> found
      {:error, :not_a_file} -> {:error, :command_not_found}
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
         output = String.replace_invalid(output),
         {:ok, emit} <- fetch_emit(decoded),
         {:ok, media} <- fetch_media(decoded),
         {:ok, chain} <- fetch_chain(decoded),
         {:ok, instructions} <- fetch_string(decoded, "instructions", ""),
         {:ok, session} <- fetch_session(decoded) do
      {:ok,
       %{
         ok: ok,
         output: output,
         emit: emit,
         media: media,
         chain: chain,
         instructions: instructions,
         session: session
       }}
    end
  end

  defp validate(decoded), do: {:error, {:invalid_output, decoded}}

  defp fetch_bool(decoded, key) do
    case Map.fetch(decoded, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_output, decoded}}
    end
  end

  defp fetch_session(decoded) do
    case Map.get(decoded, "session") do
      nil ->
        {:ok, nil}

      %{"continues" => id, "since" => since, "history" => history} = session
      when is_binary(id) and is_binary(since) and is_list(history) ->
        {:ok, session}

      _invalid ->
        {:error, {:invalid_output, decoded}}
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

  defp fetch_media(decoded) do
    case Map.get(decoded, "media", []) do
      list when is_list(list) ->
        if Enum.all?(list, &valid_media?/1),
          do: {:ok, list},
          else: {:error, {:invalid_output, decoded}}

      _ ->
        {:error, {:invalid_output, decoded}}
    end
  end

  defp valid_media?(%{"media_type" => type} = part) when is_binary(type),
    do: Enum.count(~w(data sha256 path), &is_binary(part[&1])) == 1

  defp valid_media?(_part), do: false

  defp fetch_chain(decoded) do
    case chain_steps(Map.get(decoded, "chain", [])) do
      {:ok, _steps} = ok -> ok
      :error -> {:error, {:invalid_output, decoded}}
    end
  end

  @doc "Parses a list of `{name, args}` tool calls, the shape of `out.chain`."
  @spec chain_steps(term) :: {:ok, [%{name: String.t(), args: map}]} | :error
  def chain_steps(list) when is_list(list) do
    Enum.reduce_while(Enum.reverse(list), {:ok, []}, fn entry, {:ok, acc} ->
      case chain_step(entry) do
        {:ok, step} -> {:cont, {:ok, [step | acc]}}
        :error -> {:halt, :error}
      end
    end)
  end

  def chain_steps(_list), do: :error

  defp chain_step(%{"name" => name} = entry) when is_binary(name) and name != "" do
    case Map.get(entry, "args", %{}) do
      args when is_map(args) -> {:ok, %{name: name, args: args}}
      _ -> :error
    end
  end

  defp chain_step(_entry), do: :error

  defp valid_emit_entry?(%{"type" => type, "body" => body}),
    do: is_binary(type) and is_map(body)

  defp valid_emit_entry?(_), do: false
end
