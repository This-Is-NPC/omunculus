defmodule Omunculus.Sandbox do
  @moduledoc """
  Runs the JavaScript `tools.*` bridge through a coordinator policy with no
  workspace, network, environment, or process capabilities.
  """

  alias Omunculus.Execution
  alias Omunculus.Execution.{Command, Policy, Program, Session}
  alias Omunculus.Path, as: FilesystemPath

  @spec run(
          String.t(),
          [map],
          (String.t(), map -> {:ok, String.t()} | {:error, term}),
          Policy.t()
        ) ::
          {:ok, String.t()} | {:error, term}
  def run(code, tools, call, %Policy{} = execution) when is_binary(code) do
    [program | flags] = execution.sandbox.command

    with {:ok, script} <- FilesystemPath.canonical(execution.sandbox.script),
         {:ok, policy} <- Policy.coordinator(execution, Path.dirname(script)),
         {:ok, binary} <- resolve_program(program, policy),
         {:ok, command} <- Command.new(binary, flags ++ [script], cwd: Path.dirname(script)),
         {:ok, handle} <- Execution.start(command, policy, self(), make_ref(), :coordinator) do
      try do
        :ok =
          Execution.write(
            handle,
            Jason.encode!(%{code: code, names: Enum.map(tools, & &1.name)}) <> "\n"
          )

        allowed = MapSet.new(tools, & &1.name)
        Session.serve(handle, Policy.deadline(policy), &line(&1, allowed, call), &ended/1)
      after
        Session.stop(handle)
      end
    end
  end

  defp line(line, allowed, call) do
    case Jason.decode(line) do
      {:ok, %{"type" => "call", "id" => id, "name" => name, "args" => args}}
      when is_binary(name) and is_map(args) ->
        {:reply, Session.answer(id, name, args, allowed, call)}

      {:ok, %{"type" => "result", "output" => output}} when is_binary(output) ->
        {:halt, {:ok, output}}

      {:ok, %{"type" => "error", "output" => output}} when is_binary(output) ->
        {:halt, {:error, {:javascript, output}}}

      _message ->
        {:halt, {:error, :invalid_sandbox_output}}
    end
  end

  defp ended({:exit, status}), do: {:error, {:sandbox_exit, status}}
  defp ended({:error, reason}), do: {:error, reason}
  defp ended(:timeout), do: {:error, :sandbox_timeout}

  defp resolve_program(program, policy) do
    with :error <- Program.runtime(program, policy), do: {:error, :deno_not_found}
  end
end
