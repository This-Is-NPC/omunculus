defmodule Omunculus.Sandbox do
  @moduledoc """
  Runs the JavaScript `tools.*` bridge through a coordinator policy with no
  workspace, network, environment, or process capabilities.
  """

  alias Omunculus.Execution
  alias Omunculus.Execution.{Command, Policy}
  alias Omunculus.Path, as: FilesystemPath

  @flags ~w(
    run
    --no-config
    --no-lock
    --no-prompt
    --cached-only
    --deny-read
    --deny-write
    --deny-net
    --deny-env
    --deny-run
    --deny-ffi
    --deny-sys
    --deny-import
  )

  @spec run(
          String.t(),
          [map],
          (String.t(), map -> {:ok, String.t()} | {:error, term}),
          Policy.t()
        ) ::
          {:ok, String.t()} | {:error, term}
  def run(code, tools, call, %Policy{} = execution) when is_binary(code) do
    script = Application.app_dir(:omunculus, "priv/sandbox.js")

    with {:ok, policy} <- Policy.coordinator(execution, Path.dirname(script)),
         {:ok, deno} <- deno(policy),
         {:ok, command} <- Command.new(deno, @flags ++ [script], cwd: Path.dirname(script)),
         {:ok, handle} <- Execution.start(command, policy) do
      try do
        :ok =
          Execution.write(
            handle,
            Jason.encode!(%{code: code, names: Enum.map(tools, & &1.name)}) <> "\n"
          )

        receive_output(handle, "", MapSet.new(tools, & &1.name), call, deadline(policy))
      after
        stop(handle)
      end
    end
  end

  defp receive_output(handle, buffer, allowed, call, deadline) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        handle_message(handle, rest, allowed, call, deadline, Jason.decode(line))

      [_partial] ->
        receive do
          {:execution, ref, {:stdout, bytes}} when ref == handle.ref ->
            receive_output(handle, buffer <> bytes, allowed, call, deadline)

          {:execution, ref, {:stderr, _bytes}} when ref == handle.ref ->
            receive_output(handle, buffer, allowed, call, deadline)

          {:execution, ref, {:exit, status}} when ref == handle.ref ->
            {:error, {:sandbox_exit, status}}

          {:execution, ref, {:error, reason}} when ref == handle.ref ->
            {:error, reason}
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            {:error, :sandbox_timeout}
        end
    end
  end

  defp handle_message(handle, rest, allowed, call, deadline, {
         :ok,
         %{"type" => "call", "id" => id, "name" => name, "args" => args}
       })
       when is_binary(name) and is_map(args) do
    response =
      if MapSet.member?(allowed, name) do
        case call.(name, args) do
          {:ok, output} -> %{id: id, ok: true, output: output}
          {:error, reason} -> %{id: id, ok: false, output: inspect(reason)}
        end
      else
        %{id: id, ok: false, output: inspect({:not_allowed, name})}
      end

    with :ok <- Execution.write(handle, Jason.encode!(response) <> "\n") do
      receive_output(handle, rest, allowed, call, deadline)
    end
  end

  defp handle_message(
         _handle,
         _rest,
         _allowed,
         _call,
         _deadline,
         {:ok, %{"type" => "result", "output" => output}}
       )
       when is_binary(output),
       do: {:ok, output}

  defp handle_message(
         _handle,
         _rest,
         _allowed,
         _call,
         _deadline,
         {:ok, %{"type" => "error", "output" => output}}
       )
       when is_binary(output),
       do: {:error, {:javascript, output}}

  defp handle_message(_handle, _rest, _allowed, _call, _deadline, _message),
    do: {:error, :invalid_sandbox_output}

  defp deno(policy) do
    policy.runtimes
    |> Enum.map(&Path.join([&1, "bin", "deno"]))
    |> Enum.find_value({:error, :deno_not_found}, fn path ->
      with {:ok, canonical} <- FilesystemPath.canonical(path),
           true <- File.regular?(canonical) do
        {:ok, canonical}
      else
        _ -> false
      end
    end)
  end

  defp deadline(policy), do: System.monotonic_time(:millisecond) + policy.limits.timeout_ms

  defp stop(handle) do
    Execution.stop(handle, :completed)
  catch
    :exit, _reason -> :ok
  end
end
