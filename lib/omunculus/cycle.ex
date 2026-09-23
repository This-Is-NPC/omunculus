defmodule Omunculus.Cycle do
  @moduledoc """
  The runs one command opens, each in a process of its own. `run/3` gives
  a project without a cycle one for the length of `fun`: `fun` runs in
  the caller with that cycle, then `run/3` waits until every run opened
  through it, transitively, has finished, and returns `fun`'s result, or
  the errors of `fun` and of those runs (one error as itself, several as
  `{:runs, reasons}`). With a cycle already there, `run/3` just calls
  `fun`. `open/2` makes a run due, the fields it is not given `nil`: it opens at once, concurrently with
  the others, through `Run.open/2`, which waits for a slot of the `run`
  class of the execution limiter.

  A work has one run at a time: a run due for a work that has a run open
  waits until that run finishes, and the waiting runs of a work open in
  the order they became due. A run of the work's own (an opening without
  a named agent) due while another is already waiting is merged into it.
  `link/2`, called from the process of a run the store has just linked to
  a work, makes that run the work's open run until it finishes.
  A run that does not begin because its work is no longer open, or is
  cancelled, is not an error.
  """

  use GenServer

  alias Omunculus.{Project, Run}

  @opening %{prompt_id: nil, work_id: nil, request_id: nil, inbox_id: nil, via: nil, agent: nil}

  @spec run(Project.t(), map | nil, (Project.t() -> result)) :: result | {:error, term}
        when result: term
  def run(%Project{cycle: nil} = project, opening, fun) do
    {:ok, cycle} = GenServer.start_link(__MODULE__, project)
    :ok = GenServer.call(cycle, {:claim, work_key(opening)})

    result =
      try do
        {:ok, fun.(%{project | cycle: cycle})}
      catch
        kind, reason -> {:caught, kind, reason, __STACKTRACE__}
      end

    :ok = GenServer.call(cycle, :settle)
    errors = GenServer.call(cycle, :await, :infinity)
    GenServer.stop(cycle)

    case result do
      {:ok, value} -> combine(value, errors)
      {:caught, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  def run(%Project{} = project, _opening, fun), do: fun.(project)

  @spec link(Project.t(), String.t()) :: :ok
  def link(%Project{cycle: cycle}, work_id) when is_pid(cycle),
    do: GenServer.cast(cycle, {:link, self(), work_id})

  @spec open(Project.t(), map) :: :ok
  def open(%Project{cycle: cycle}, fields) when is_pid(cycle),
    do: GenServer.cast(cycle, {:open, Map.merge(@opening, fields)})

  @impl true
  def init(project) do
    {:ok,
     %{
       project: %{project | cycle: self()},
       running: %{},
       works: %{},
       errors: [],
       waiter: nil
     }}
  end

  @impl true
  # The caller of `run/3` is a running entry like any run's process.
  def handle_call({:claim, key}, {caller, _tag}, state),
    do: {:reply, :ok, hold(%{state | running: Map.put(state.running, caller, key)}, key)}

  def handle_call(:settle, {caller, _tag}, state) do
    {key, running} = Map.pop(state.running, caller)
    {:reply, :ok, settle(%{state | running: running}, key)}
  end

  def handle_call(:await, from, state), do: reply_when_idle(%{state | waiter: from})

  @impl true
  def handle_cast({:open, opening}, state) do
    key = work_key(opening)

    state =
      case Map.fetch(state.works, key) do
        _any when is_nil(key) -> start(state, opening)
        :error -> start(hold(state, key), opening)
        {:ok, waiting} -> %{state | works: Map.put(state.works, key, wait(waiting, opening))}
      end

    {:noreply, state}
  end

  def handle_cast({:link, pid, work_id}, state) do
    case Map.fetch(state.running, pid) do
      {:ok, nil} ->
        {:noreply, hold(%{state | running: Map.put(state.running, pid, work_id)}, work_id)}

      _held_or_unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:finished, pid, result}, state) do
    {key, running} = Map.pop(state.running, pid)

    %{state | running: running, errors: record(state.errors, result)}
    |> settle(key)
    |> reply_when_idle()
  end

  defp start(state, opening) do
    cycle = self()
    project = state.project
    pid = spawn_link(fn -> send(cycle, {:finished, self(), open_run(project, opening)}) end)
    %{state | running: Map.put(state.running, pid, work_key(opening))}
  end

  defp open_run(project, opening) do
    Run.open(project, opening)
  rescue
    exception -> {:error, {:run_crashed, exception}}
  catch
    kind, reason -> {:error, {:run_crashed, {kind, reason}}}
  end

  defp hold(state, nil), do: state
  defp hold(state, key), do: %{state | works: Map.put_new(state.works, key, [])}

  defp settle(state, nil), do: state

  defp settle(state, key) do
    case Map.fetch(state.works, key) do
      {:ok, []} -> %{state | works: Map.delete(state.works, key)}
      {:ok, [next | waiting]} -> start(%{state | works: Map.put(state.works, key, waiting)}, next)
      :error -> state
    end
  end

  defp reply_when_idle(%{waiter: from, running: running} = state)
       when from != nil and map_size(running) == 0 do
    GenServer.reply(from, Enum.reverse(state.errors))
    {:noreply, %{state | waiter: nil}}
  end

  defp reply_when_idle(state), do: {:noreply, state}

  defp record(errors, {:error, {reason, _work_id}}) when reason in [:not_open, :cancelled],
    do: errors

  defp record(errors, {:error, reason}), do: [reason | errors]
  defp record(errors, _ok), do: errors

  defp wait(waiting, %{agent: nil} = opening) do
    if Enum.any?(waiting, &is_nil(&1.agent)), do: waiting, else: waiting ++ [opening]
  end

  defp wait(waiting, opening), do: waiting ++ [opening]

  defp work_key(%{work_id: work_id}) when is_binary(work_id), do: work_id
  defp work_key(_opening), do: nil

  defp combine(result, []), do: result
  defp combine({:error, reason}, errors), do: errors_result([reason | errors])
  defp combine(_ok, errors), do: errors_result(errors)

  defp errors_result([reason]), do: {:error, reason}
  defp errors_result(reasons), do: {:error, {:runs, reasons}}
end
