defmodule Omunculus.Jobs.Policy do
  @moduledoc """
  The project's `[jobs]` table: the limits and the policy scheduled jobs run
  under. Jobs themselves are data in the store; nothing here has a default,
  so a project without the table has no jobs and a table must give every
  key.

  | Key | Meaning |
  | --- | --- |
  | `max_parallel` | Fires of the project that run at once. |
  | `min_interval_minutes` | The shortest gap a schedule may have between fires. |
  | `max_jobs` | Jobs a project holds that are not archived. |
  | `missed` | What a fire missed while the server was down becomes: `skip` or `run_once`. |
  | `lateness_seconds` | How long after its time a fire may still start before it is late. |
  | `failures_before_pause` | Consecutive failed fires that pause a job. |
  | `agent_may_create` | Whether an agent's `propose_job` creates the job without a request. |
  """

  @integers ~w(max_parallel min_interval_minutes max_jobs lateness_seconds failures_before_pause)
  @keys @integers ++ ~w(missed agent_may_create)
  @missed ~w(skip run_once)

  @type t :: %{
          max_parallel: pos_integer,
          min_interval_minutes: pos_integer,
          max_jobs: pos_integer,
          missed: String.t(),
          lateness_seconds: pos_integer,
          failures_before_pause: pos_integer,
          agent_may_create: boolean
        }

  @spec parse(map | nil) :: {:ok, t | nil} | {:error, term}
  def parse(nil), do: {:ok, nil}

  def parse(table) when is_map(table) do
    with [] <- Map.keys(table) -- @keys,
         nil <- Enum.find(@keys, &(not Map.has_key?(table, &1))) do
      case Enum.find(@keys, &(not valid?(&1, table[&1]))) do
        nil -> {:ok, Map.new(table, fn {key, value} -> {String.to_atom(key), value} end)}
        key -> {:error, {:jobs, {:invalid, key}}}
      end
    else
      [key | _] when is_binary(key) -> {:error, {:jobs, {:unknown_key, key}}}
      key -> {:error, {:jobs, {:missing, key}}}
    end
  end

  def parse(_other), do: {:error, {:jobs, :invalid}}

  defp valid?(key, value) when key in @integers, do: is_integer(value) and value > 0
  defp valid?("missed", value), do: value in @missed
  defp valid?("agent_may_create", value), do: is_boolean(value)
end
