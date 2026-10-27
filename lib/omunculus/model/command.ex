defmodule Omunculus.Model.Command do
  @moduledoc """
  Factory for a `command` model of the model contract: `new/1`
  takes the `[models.<name>]` spec (`command`, `model`, optional
  `params`, `credential`) and returns a 6-arity
  `(prompt, tools, call, record, delta, execution)` fun. Starts `command`
  through `Execution` under the run's policy, writes one JSON line
  `{instructions, context, tools, credential, model, params}`, then speaks the
  sandbox NDJSON protocol: the program emits `{type: call, name, args}`
  lines (optional `id`, as in `priv/sandbox.js`); each is answered and
  recorded; `{type: delta, text}` passes partial text to `delta`
  without recording it; `{type: text, output}` ends the turn. The argv is always
  the spec's; nothing in this module names a host.
  """

  alias Omunculus.Execution
  alias Omunculus.Execution.{Command, Policy, Session}
  alias Omunculus.Path, as: FilesystemPath
  alias Omunculus.Prompt

  @spec new(map) ::
          (Prompt.t(),
           [map],
           (String.t(), map -> {:ok, String.t()} | {:error, term}),
           (map -> :ok | {:error, term}),
           (String.t() -> :ok),
           Policy.t() ->
             {:ok, String.t()} | {:error, term})
  def new(spec) when is_map(spec) do
    fn %Prompt{} = prompt, tools, call, record, delta, execution ->
      run(spec, prompt, tools, %{call: call, record: record, delta: delta}, execution)
    end
  end

  defp run(spec, prompt, tools, turn, %Policy{} = execution) do
    argv = spec["command"]

    with {:ok, command} <- external_command(argv, execution) do
      ref = make_ref()

      case Execution.start(command, execution, self(), ref) do
        {:ok, handle} ->
          try do
            payload =
              Jason.encode!(%{
                instructions: prompt.instructions,
                context: prompt.context,
                tools: tools,
                credential: credential(spec),
                model: spec["model"],
                params: spec["params"] || %{}
              })

            turn = Map.put(turn, :allowed, MapSet.new(tools, & &1.name))

            with :ok <- Execution.write(handle, payload <> "\n") do
              Session.serve(handle, Policy.deadline(execution), &line(&1, turn), &ended/1)
            end
          after
            Session.stop(handle)
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

  defp line("", _turn), do: :cont
  defp line(line, turn), do: message(Jason.decode(line), turn)

  defp message({:ok, %{"type" => "call", "name" => name} = message}, turn)
       when is_binary(name) do
    args = Map.get(message, "args") || %{}
    args = if is_map(args), do: args, else: %{}

    case turn.record.(message) do
      :ok -> {:reply, Session.answer(Map.get(message, "id"), name, args, turn.allowed, turn.call)}
      error -> {:halt, error}
    end
  end

  defp message({:ok, %{"type" => "delta", "text" => text}}, turn) when is_binary(text) do
    :ok = turn.delta.(text)
    :cont
  end

  defp message({:ok, %{"type" => type, "output" => output} = message}, turn)
       when type in ["text", "result"] and is_binary(output) do
    case turn.record.(message) do
      :ok -> {:halt, {:ok, output}}
      error -> {:halt, error}
    end
  end

  defp message({:ok, %{"type" => "error", "output" => output}}, _turn) when is_binary(output),
    do: {:halt, {:error, {:command, output}}}

  defp message({:error, reason}, _turn),
    do: {:halt, {:error, {:command, {:invalid_json, reason}}}}

  defp message(_message, _turn), do: {:halt, {:error, {:command, :invalid_output}}}

  defp ended({:exit, 0}), do: {:error, {:command, :closed}}
  defp ended({:exit, status}), do: {:error, {:command, {:exit, status}}}
  defp ended({:error, reason}), do: {:error, {:command, reason}}
  defp ended(:timeout), do: {:error, {:command, :timeout}}

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
end
