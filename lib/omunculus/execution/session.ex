defmodule Omunculus.Execution.Session do
  @moduledoc """
  Speaks to a started execution over its stdin and stdout: the NDJSON
  protocol of `priv/sandbox.js` and of a `command` model, where each stdout
  line is one message and a `call` line is answered with one stdin line
  `{id, ok, output}`. Stderr is ignored.
  """

  alias Omunculus.Execution
  alias Omunculus.Tools.Out

  @type step :: :cont | {:reply, map} | {:halt, term}
  @type ending :: {:exit, non_neg_integer} | {:error, term} | :timeout

  @doc """
  Reads `handle`'s stdout line by line until `deadline`. `on_line` takes each
  line without its newline and keeps reading (`:cont`), writes a response
  and keeps reading (`{:reply, response}`), or returns a result
  (`{:halt, result}`). `on_end` turns the process ending first, or the
  deadline passing, into the result.
  """
  @spec serve(Execution.Handle.t(), integer, (String.t() -> step), (ending -> term)) :: term
  def serve(handle, deadline, on_line, on_end),
    do: serve(handle, "", deadline, on_line, on_end)

  defp serve(handle, buffer, deadline, on_line, on_end) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        case on_line.(line) do
          :cont ->
            serve(handle, rest, deadline, on_line, on_end)

          {:reply, response} ->
            with :ok <- Execution.write(handle, Jason.encode!(response) <> "\n") do
              serve(handle, rest, deadline, on_line, on_end)
            end

          {:halt, result} ->
            result
        end

      [_partial] ->
        receive do
          {:execution, ref, {:stdout, bytes}} when ref == handle.ref ->
            serve(handle, buffer <> bytes, deadline, on_line, on_end)

          {:execution, ref, {:stderr, _bytes}} when ref == handle.ref ->
            serve(handle, buffer, deadline, on_line, on_end)

          {:execution, ref, {:exit, status}} when ref == handle.ref ->
            on_end.({:exit, status})

          {:execution, ref, {:error, reason}} when ref == handle.ref ->
            on_end.({:error, reason})
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            on_end.(:timeout)
        end
    end
  end

  @doc """
  The response to a `call` of `name` with `args`: `call`'s output when
  `allowed` holds `name`, a refusal otherwise; it carries `id` unless nil.
  """
  @spec answer(
          term,
          String.t(),
          map,
          MapSet.t(String.t()),
          (String.t(), map -> {:ok, String.t()} | {:error, term})
        ) :: map
  def answer(id, name, args, allowed, call) do
    result =
      if MapSet.member?(allowed, name) do
        case call.(name, args) do
          {:ok, output} -> %{ok: true, output: output}
          {:error, reason} -> %{ok: false, output: Out.failure(reason)}
        end
      else
        %{ok: false, output: Out.not_yours(name)}
      end

    if is_nil(id), do: result, else: Map.put(result, :id, id)
  end

  @doc "Stops `handle`; a process already gone counts as stopped."
  @spec stop(Execution.Handle.t()) :: :ok | {:error, term}
  def stop(handle) do
    Execution.stop(handle, :completed)
  catch
    :exit, _reason -> :ok
  end
end
