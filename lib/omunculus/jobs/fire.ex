defmodule Omunculus.Jobs.Fire do
  @moduledoc """
  One fire of a job, from its condition to its record.

  `condition/2` runs the job's condition tool, as the owner and without a
  model: its output is a JSON object whose `run` is `false` to skip the fire,
  with a `reason`, and whose `pause` is `true` to also pause the job because
  its entitlement is gone. A tool that fails or answers anything else skips
  the fire with that as the reason, spending nothing.

  `run/3` opens the work of a fire already recorded `running`, as the owner
  and with `via = "job"`, the way `send` does: a message to the job's agent,
  a root work for its workflow, or the call of its tool. It waits for the
  runs that opened, then records `succeeded` or `failed` with the conversation,
  the runs, the duration and what the runs cost (`Omunculus.Jobs.Cost`), and,
  for a job that delivers, the replies as the `message`.
  """

  alias Omunculus.{Config, Cycle, Errors, Jobs, Operations}
  alias Omunculus.Jobs.{Cost, Notice}
  alias Omunculus.Store.Access

  @spec condition(Omunculus.Project.t(), map) ::
          :run | {:skip, String.t()} | {:pause, String.t()}
  def condition(_project, %{"condition" => nil}), do: :run

  def condition(project, job) do
    actor = %{principal: principal(job["owner"])}

    case Operations.call(project, job["condition"], job["condition_args"] || %{}, actor, false) do
      {:ok, %{ok: true, output: output}, _events} -> verdict(output)
      {:ok, %{output: output}, _events} -> {:skip, "the condition failed: #{output}"}
      {:error, reason} -> {:skip, "the condition failed: #{Errors.format(reason)}"}
    end
  end

  defp verdict(output) do
    case Jason.decode(output) do
      {:ok, %{"run" => true}} -> :run
      {:ok, %{"run" => false, "pause" => true} = said} -> {:pause, reason(said)}
      {:ok, %{"run" => false} = said} -> {:skip, reason(said)}
      _other -> {:skip, "the condition did not answer {\"run\": true|false}: #{output}"}
    end
  end

  defp reason(%{"reason" => reason}) when is_binary(reason) and reason != "", do: reason
  defp reason(_said), do: "the condition said no"

  @doc "Runs the `running` `fire` of `job` and records how it ended."
  @spec run(Omunculus.Project.t(), map, map) :: :ok | {:error, term}
  def run(project, job, fire) do
    started = System.monotonic_time(:millisecond)
    outcome = execute(project, job)
    duration = System.monotonic_time(:millisecond) - started
    conn = project.conn

    with {:ok, config} <- Config.load(project.config_path),
         {:ok, attrs} <- record(project, config, job, outcome) do
      attrs = Map.merge(attrs, %{"fire_id" => fire["fire_id"], "duration_ms" => duration})

      with {:ok, _fire} <- Jobs.record_fire(conn, job["id"], attrs),
           do: pause_after_failures(project, config, job["id"])
    end
  end

  @doc """
  Pauses `job`, when it is active, with the `reason`, and tells its owner.
  """
  @spec pause(Omunculus.Store.Connection.t(), map, String.t()) :: :ok | {:error, term}
  def pause(conn, %{"state" => "active"} = job, reason) do
    with {:ok, _event} <- Jobs.transition(conn, job["id"], "paused", reason),
         do: Notice.owner(conn, job, "paused: #{reason}")
  end

  def pause(_conn, _job, _reason), do: :ok

  @doc """
  Pauses the job `id` once `[jobs] failures_before_pause` fires in a row
  have failed since it last started or resumed; fires that were skipped or
  missed do not break the row.
  """
  @spec pause_after_failures(Omunculus.Project.t(), Config.t(), String.t()) ::
          :ok | {:error, term}
  def pause_after_failures(project, config, id) do
    with {:ok, job} <- Jobs.get(project.conn, id),
         {:ok, fires} <- Jobs.fires(project.conn, id) do
      failed =
        fires
        |> Enum.reverse()
        |> Enum.filter(&(&1["state"] in ~w(succeeded failed) and &1["at"] > job["anchor"]))
        |> Enum.take_while(&(&1["state"] == "failed"))

      if length(failed) >= config.jobs.failures_before_pause,
        do:
          pause(
            project.conn,
            job,
            "#{length(failed)} fires failed in a row: #{hd(failed)["reason"]}"
          ),
        else: :ok
    end
  end

  # What one fire does: opens its work and waits for the runs it caused.
  defp execute(project, job) do
    principal = principal(job["owner"])

    with {:ok, conversation_id} <- conversation(project, job, principal),
         actor = %{principal: principal, conversation_id: conversation_id, via: "job"},
         {:ok, started} <-
           Cycle.command(project, nil, fn project ->
             {name, args} = request(job)
             Operations.start(project, name, args, actor)
           end) do
      {:ok, conversation_id, started}
    end
  catch
    kind, reason -> {:error, {:run_crashed, {kind, reason}}}
  end

  defp record(project, config, job, {:ok, conversation_id, {_out, ids} = started}) do
    conn = project.conn

    with {:ok, run_ids} <- Cost.runs(conn, ids),
         {:ok, cost} <- Cost.of_runs(conn, config, run_ids) do
      {:ok,
       %{"state" => "succeeded", "run_ids" => run_ids}
       |> Map.merge(counters(cost))
       |> put("conversation_id", conversation_id)
       |> put("message", message(project, job, started))}
    end
  end

  defp record(_project, _config, _job, {:error, reason}),
    do: {:ok, %{"state" => "failed", "reason" => Errors.format(reason)}}

  defp counters(cost),
    do: %{
      "calls" => cost.calls,
      "input_tokens" => cost.input_tokens,
      "output_tokens" => cost.output_tokens,
      "usd" => cost.usd
    }

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp message(project, %{"delivery" => "owner_inbox"}, started) do
    reply = Operations.reply(project, started)
    if reply == "", do: nil, else: reply
  end

  defp message(_project, _job, _started), do: nil

  defp request(%{"agent" => agent, "message" => message}),
    do: {"send", %{"agent" => agent, "message" => message}}

  defp request(%{"workflow" => workflow, "message" => message} = job) do
    item =
      %{"title" => job["name"], "goal" => message, "workflow" => workflow}
      |> put("workspace", job["workspace"])

    {"work", %{"report" => message, "works" => [item]}}
  end

  defp request(%{"tool" => tool, "args" => args}), do: {tool, args || %{}}

  # A job with a conversation of its own sends to it; else each fire opens one
  # when the project has conversations.
  defp conversation(_project, %{"tool" => tool}, _principal) when is_binary(tool), do: {:ok, nil}

  defp conversation(_project, %{"conversation_id" => id}, _principal) when is_binary(id),
    do: {:ok, id}

  defp conversation(project, _job, principal) do
    with {:ok, config} <- Config.load(project.config_path) do
      if is_map(config.access) do
        with {:ok, %{id: id}} <- Access.create_conversation(project, principal), do: {:ok, id}
      else
        {:ok, nil}
      end
    end
  end

  @doc "The principal a job's owner acts as."
  @spec principal(map) :: Access.principal()
  def principal(%{"kind" => "human", "issuer" => issuer, "subject" => subject}),
    do: %{issuer: issuer, subject: subject}

  def principal(%{"kind" => "agent", "agent" => agent}), do: %{issuer: "agent", subject: agent}
end
