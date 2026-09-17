defmodule Omunculus.Model.Command do
  @moduledoc """
  Factory for a `command` model of the contract of spec §8.6: `new/1`
  takes the `[models.<name>]` spec (`command`, `model`, optional
  `params`, `credential`) and returns a 5-arity
  `(assembled, tools, call, record, execution)` fun. Starts `command`
  through `Execution` under the run's policy, writes one JSON line
  `{assembled, tools, credential, model, params}`, then speaks the
  sandbox NDJSON protocol: the program emits `{type: call, name, args}`
  lines (optional `id`, as in `priv/sandbox.js`); each is answered and
  recorded; `{type: text, output}` ends the turn. The argv is always
  the spec's; nothing in this module names a host.
  """

  alias Omunculus.Execution
  alias Omunculus.Execution.{Command, Policy}
  alias Omunculus.Path, as: FilesystemPath

  @spec new(map) ::
          (String.t(),
           [map],
           (String.t(), map -> {:ok, String.t()} | {:error, term}),
           (map -> :ok | {:error, term}),
           Policy.t() ->
             {:ok, String.t()} | {:error, term})
  def new(spec) when is_map(spec) do
    fn assembled, tools, call, record, execution ->
      run(spec, assembled, tools, call, record, execution)
    end
  end

  defp run(spec, assembled, tools, call, record, %Policy{} = execution) do
    argv = spec["command"]
    allowed = MapSet.new(tools, & &1.name)

    with {:ok, command} <- external_command(argv, execution) do
      ref = make_ref()

      case Execution.start(command, execution, self(), ref) do
        {:ok, handle} ->
          try do
            payload =
              Jason.encode!(%{
                assembled: assembled,
                tools: tools,
                credential: credential(spec),
                model: spec["model"],
                params: spec["params"] || %{}
              })

            with :ok <- Execution.write(handle, payload <> "\n") do
              receive_output(handle, "", allowed, call, record, deadline(execution))
            end
          after
            stop(handle)
          end

        {:error, reason} ->
          {:error, {:command, reason}}
      end
    end
  end

  defp credential(spec) do
    case Map.get(spec, "credential") do
      %{"access" => _} = cred -> cred
      %{access: access} -> %{"access" => access, "expires_at" => Map.get(spec, :expires_at)}
      _absent -> nil
    end
  end

  defp receive_output(handle, buffer, allowed, call, record, deadline) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        handle_message(handle, rest, allowed, call, record, deadline, decode_line(line))

      [_partial] ->
        receive do
          {:execution, ref, {:stdout, bytes}} when ref == handle.ref ->
            receive_output(handle, buffer <> bytes, allowed, call, record, deadline)

          {:execution, ref, {:stderr, _bytes}} when ref == handle.ref ->
            receive_output(handle, buffer, allowed, call, record, deadline)

          {:execution, ref, {:exit, 0}} when ref == handle.ref ->
            {:error, {:command, :closed}}

          {:execution, ref, {:exit, status}} when ref == handle.ref ->
            {:error, {:command, {:exit, status}}}

          {:execution, ref, {:error, reason}} when ref == handle.ref ->
            {:error, {:command, reason}}
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            {:error, {:command, :timeout}}
        end
    end
  end

  defp decode_line(""), do: :skip

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_message(handle, rest, allowed, call, record, deadline, :skip) do
    receive_output(handle, rest, allowed, call, record, deadline)
  end

  defp handle_message(
         handle,
         rest,
         allowed,
         call,
         record,
         deadline,
         {:ok, %{"type" => "call", "name" => name} = message}
       )
       when is_binary(name) do
    args = Map.get(message, "args") || %{}
    args = if is_map(args), do: args, else: %{}

    with :ok <- record.(message) do
      response = answer(message, name, args, allowed, call)

      with :ok <- Execution.write(handle, Jason.encode!(response) <> "\n") do
        receive_output(handle, rest, allowed, call, record, deadline)
      end
    end
  end

  defp handle_message(
         _handle,
         _rest,
         _allowed,
         _call,
         record,
         _deadline,
         {:ok, %{"type" => type, "output" => output} = message}
       )
       when type in ["text", "result"] and is_binary(output) do
    with :ok <- record.(message) do
      {:ok, output}
    end
  end

  defp handle_message(
         _handle,
         _rest,
         _allowed,
         _call,
         _record,
         _deadline,
         {:ok, %{"type" => "error", "output" => output}}
       )
       when is_binary(output),
       do: {:error, {:command, output}}

  defp handle_message(_handle, _rest, _allowed, _call, _record, _deadline, {:error, reason}),
    do: {:error, {:command, {:invalid_json, reason}}}

  defp handle_message(_handle, _rest, _allowed, _call, _record, _deadline, _message),
    do: {:error, {:command, :invalid_output}}

  defp answer(message, name, args, allowed, call) do
    result =
      if MapSet.member?(allowed, name) do
        case call.(name, args) do
          {:ok, output} -> %{ok: true, output: output}
          {:error, reason} -> %{ok: false, output: inspect(reason)}
        end
      else
        %{ok: false, output: inspect({:not_allowed, name})}
      end

    case Map.get(message, "id") do
      nil -> result
      id -> Map.put(result, :id, id)
    end
  end

  defp external_command([program | args], policy) when is_binary(program) do
    with {:ok, executable} <- executable(program, policy),
         {:ok, command} <- Command.new(executable, args, cwd: policy.workspace.root) do
      {:ok, command}
    else
      {:error, reason} -> {:error, {:command, reason}}
    end
  end

  defp external_command(_argv, _policy), do: {:error, {:command, :invalid_command}}

  defp executable(program, policy) do
    if Path.type(program) == :absolute or String.contains?(program, "/") do
      case FilesystemPath.canonical(program) do
        {:ok, path} ->
          if File.regular?(path), do: {:ok, path}, else: {:error, :command_not_found}

        {:error, reason} ->
          {:error, reason}
      end
    else
      policy.runtimes
      |> Enum.map(&Path.join([&1, "bin", program]))
      |> Enum.find_value({:error, :command_not_found}, fn path ->
        case FilesystemPath.canonical(path) do
          {:ok, executable} -> {:ok, executable}
          {:error, _reason} -> false
        end
      end)
    end
  end

  defp deadline(policy), do: System.monotonic_time(:millisecond) + policy.limits.timeout_ms

  defp stop(handle) do
    Execution.stop(handle, :completed)
  catch
    :exit, _reason -> :ok
  end
end
