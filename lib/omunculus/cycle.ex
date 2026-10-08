defmodule Omunculus.Cycle do
  @moduledoc """
  The runs commands open, each in a process of its own. `run/3` gives a
  project without a cycle one for the length of `fun`; with a cycle
  already there, it just calls `fun`. `command/3` runs `fun` in the caller
  as one command of the project's cycle, then waits until every run the
  command opened, transitively, has finished, and returns `fun`'s result,
  or the errors of `fun` and of those runs (one error as itself, several
  as `{:runs, reasons}`). A run belongs to the command of the process that
  made it due; in a cycle `run/3` started, every run belongs to its
  command. `open/2` makes a run due, the fields it is not given `nil`: it
  opens at once, concurrently with the others, through `Run.open/2`,
  which waits for a slot of the `run` class of the execution limiter.

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

  @opening %{
    prompt_id: nil,
    work_id: nil,
    request_id: nil,
    inbox_id: nil,
    via: nil,
    agent: nil,
    conversation_id: nil,
    cause_id: nil
  }

  @spec start_link(Project.t()) :: GenServer.on_start()
  def start_link(project), do: GenServer.start_link(__MODULE__, project)

  @spec run(Project.t(), map | nil, (Project.t() -> result)) :: result | {:error, term}
        when result: term
  def run(%Project{cycle: nil} = project, opening, fun) do
    {:ok, cycle} = start_link(project)

    try do
      within(%{project | cycle: cycle}, opening, fun, true)
    after
      GenServer.stop(cycle)
    end
  end

  def run(%Project{} = project, _opening, fun), do: fun.(project)

  @spec command(Project.t(), map | nil, (Project.t() -> result)) :: result | {:error, term}
        when result: term
  def command(%Project{cycle: cycle} = project, opening, fun) when is_pid(cycle),
    do: within(project, opening, fun, false)

  defp within(%Project{cycle: cycle} = project, opening, fun, whole_cycle?) do
    group = GenServer.call(cycle, {:claim, work_key(opening), whole_cycle?})

    result =
      try do
        {:ok, fun.(project)}
      catch
        kind, reason -> {:caught, kind, reason, __STACKTRACE__}
      end

    :ok = GenServer.call(cycle, :settle)
    errors = GenServer.call(cycle, {:await, group}, :infinity)

    case result do
      {:ok, value} -> combine(value, errors)
      {:caught, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  @spec link(Project.t(), String.t()) :: :ok
  def link(%Project{cycle: cycle}, work_id) when is_pid(cycle),
    do: GenServer.cast(cycle, {:link, self(), work_id})

  @spec open(Project.t(), map) :: :ok
  def open(%Project{cycle: cycle}, fields) when is_pid(cycle),
    do: GenServer.cast(cycle, {:open, Map.merge(@opening, fields), self()})

  @impl true
  def init(project) do
    {:ok,
     %{
       project: %{project | cycle: self()},
       running: %{},
       works: %{},
       errors: %{},
       waiters: %{},
       idle: nil,
       whole: nil
     }}
  end

  @impl true
  # The caller of a command is a running entry like any run's process.
  def handle_call({:claim, key, whole_cycle?}, {caller, _tag}, state) do
    group = make_ref()
    entry = %{key: key, group: group, monitor: Process.monitor(caller)}
    state = %{state | running: Map.put(state.running, caller, entry)}
    state = if whole_cycle?, do: %{state | whole: group}, else: state
    {:reply, group, hold(state, key)}
  end

  def handle_call(:settle, {caller, _tag}, state), do: {:reply, :ok, leave(state, caller)}

  def handle_call({:await, group}, from, state),
    do: reply_when_idle(%{state | waiters: Map.put(state.waiters, group, from)})

  def handle_call(:await, from, state), do: reply_when_idle(%{state | idle: from})

  @impl true
  def handle_cast({:open, opening, sender}, state) do
    key = work_key(opening)

    group =
      case Map.fetch(state.running, sender) do
        {:ok, entry} -> entry.group
        :error -> state.whole
      end

    state =
      case Map.fetch(state.works, key) do
        _any when is_nil(key) -> start(state, opening, group)
        :error -> start(hold(state, key), opening, group)
        {:ok, waiting} -> put_in(state.works[key], wait(waiting, {opening, group}))
      end

    {:noreply, state}
  end

  def handle_cast({:link, pid, work_id}, state) do
    case Map.fetch(state.running, pid) do
      {:ok, %{key: nil} = entry} ->
        state = %{state | running: Map.put(state.running, pid, %{entry | key: work_id})}
        {:noreply, hold(state, work_id)}

      _held_or_unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:finished, pid, result}, state) do
    group = state.running |> Map.fetch!(pid) |> Map.fetch!(:group)

    %{state | errors: record(state.errors, group, result)}
    |> leave(pid)
    |> reply_when_idle()
  end

  # A command's caller that exits before it settles leaves its runs behind.
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state),
    do: state |> leave(pid) |> reply_when_idle()

  defp leave(state, pid) do
    case Map.pop(state.running, pid) do
      {nil, _running} ->
        state

      {entry, running} ->
        if entry.monitor, do: Process.demonitor(entry.monitor, [:flush])
        settle(%{state | running: running}, entry.key)
    end
  end

  defp start(state, opening, group) do
    cycle = self()
    project = state.project
    pid = spawn_link(fn -> send(cycle, {:finished, self(), open_run(project, opening)}) end)
    entry = %{key: work_key(opening), group: group, monitor: nil}
    %{state | running: Map.put(state.running, pid, entry)}
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
      {:ok, []} ->
        %{state | works: Map.delete(state.works, key)}

      {:ok, [{next, group} | waiting]} ->
        start(%{state | works: Map.put(state.works, key, waiting)}, next, group)

      :error ->
        state
    end
  end

  defp reply_when_idle(state) do
    {done, waiters} = Map.split_with(state.waiters, fn {group, _from} -> idle?(state, group) end)

    Enum.each(done, fn {group, from} ->
      GenServer.reply(from, Enum.reverse(Map.get(state.errors, group, [])))
    end)

    state = %{state | waiters: waiters, errors: Map.drop(state.errors, Map.keys(done))}

    if state.idle && map_size(state.running) == 0 do
      GenServer.reply(state.idle, :ok)
      {:noreply, %{state | idle: nil}}
    else
      {:noreply, state}
    end
  end

  defp idle?(state, group) do
    not Enum.any?(state.running, fn {_pid, entry} -> entry.group == group end) and
      not Enum.any?(state.works, fn {_key, waiting} ->
        Enum.any?(waiting, &(elem(&1, 1) == group))
      end)
  end

  defp record(errors, _group, {:error, {reason, _work_id}})
       when reason in [:not_open, :cancelled],
       do: errors

  defp record(errors, nil, _result), do: errors

  defp record(errors, group, {:error, reason}),
    do: Map.update(errors, group, [reason], &[reason | &1])

  defp record(errors, _group, _ok), do: errors

  defp wait(waiting, {%{agent: nil}, _group} = entry) do
    if Enum.any?(waiting, fn {opening, _group} -> is_nil(opening.agent) end),
      do: waiting,
      else: waiting ++ [entry]
  end

  defp wait(waiting, entry), do: waiting ++ [entry]

  defp work_key(%{work_id: work_id}) when is_binary(work_id), do: work_id
  defp work_key(_opening), do: nil

  defp combine(result, []), do: result
  defp combine({:error, reason}, errors), do: errors_result([reason | errors])
  defp combine(_ok, errors), do: errors_result(errors)

  defp errors_result([reason]), do: {:error, reason}
  defp errors_result(reasons), do: {:error, {:runs, reasons}}
end
