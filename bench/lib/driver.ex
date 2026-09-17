defmodule Omunculus.Benchmark.Driver do
  @moduledoc "Linear resident-run benchmark, compiled only with MIX_ENV=bench."

  alias Omunculus.{Config, Id, Project, Run}
  alias Omunculus.Model.OpenAI
  alias Omunculus.Store.Query

  def main do
    {:ok, _} = Application.ensure_all_started(:omunculus)
    config = System.fetch_env!("OMUNCULUS_BENCH_CONFIG") |> File.read!() |> Jason.decode!()
    run(config)
  rescue
    error ->
      emit(%{type: "failure", reason: Exception.message(error)})
      System.halt(2)
  end

  def run(config) do
    # A dedicated benchmark pool prevents the production default of 50 HTTP/1
    # connections from substituting a software cap for the requested hardware test.
    Req.default_options(finch: [size: 65_536])
    File.mkdir_p!(config["work_dir"])
    File.write!(Path.join(config["work_dir"], "omunculus.toml"), project_config())
    {:ok, project} = Project.open(config["work_dir"])
    :ok = Project.close(project)
    {:ok, supervisor} = Task.Supervisor.start_link()

    emit(%{
      type: "ready",
      schedulers: :erlang.system_info(:schedulers_online),
      context_bytes: config["context_bytes"],
      http_pool_size: 65_536,
      database: "shared",
      step: 1,
      interval_ms: config["interval_ms"]
    })

    grow(config, supervisor, 0)
  end

  defp grow(config, supervisor, count) do
    if config["max_agents"] && count >= config["max_agents"] do
      emit(%{type: "limit", agents: count})
      # The observer records the confirmed HTTP residency before stopping us.
      receive do
        :stop -> :ok
      end
    else
      agent = count + 1
      parent = self()
      started = System.monotonic_time(:millisecond)
      emit(%{type: "launch", agent: agent})

      {:ok, _pid} =
        Task.Supervisor.start_child(supervisor, fn -> resident(config, parent, agent) end)

      receive do
        {:resident, ^agent, assembled_bytes} ->
          emit(%{type: "resident", agents: agent, assembled_bytes: assembled_bytes})
          remaining = config["interval_ms"] - (System.monotonic_time(:millisecond) - started)

          receive do
            {:failed, failed_agent, reason} -> fail(failed_agent, reason)
          after
            max(remaining, 0) -> grow(config, supervisor, agent)
          end

        {:failed, failed_agent, reason} ->
          fail(failed_agent, reason)
      after
        30_000 -> fail(agent, "agent_start_timeout")
      end
    end
  end

  defp resident(config, parent, agent) do
    # One connection per actor, with admission serialized until Run.open has
    # persisted its state. Existing runs stay alive waiting on the Rust model.
    {:ok, project} = Project.open(config["work_dir"])

    try do
      prompt_id = Id.new()
      block = :crypto.hash(:sha256, Integer.to_string(agent)) |> Base.encode16(case: :lower)
      size = config["context_bytes"]
      body = binary_part(:binary.copy(block, div(size, byte_size(block)) + 1), 0, size)

      :ok =
        Query.insert(project.conn, :prompts, %{
          id: prompt_id,
          kind: "message",
          body: body,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      model = OpenAI.new(config["model_url"] <> "/v1", "benchmark", timeout: 86_460_000)

      wrapped = fn assembled, tools, call, record, execution ->
        send(parent, {:resident, agent, byte_size(assembled)})
        model.(assembled, tools, call, record, execution)
      end

      opening = %{prompt_id: prompt_id, work_id: nil, request_id: nil, agent: nil, via: nil}
      result = Run.open(project, opening, wrapped)
      send(parent, {:failed, agent, inspect(result, limit: 10, printable_limit: 2000)})
    after
      Project.close(project)
    end
  rescue
    error -> send(parent, {:failed, agent, Exception.message(error)})
  catch
    kind, reason -> send(parent, {:failed, agent, inspect({kind, reason})})
  end

  defp project_config do
    Config.Toml.encode(%{
      "execution" => %{
        "backend" => "bubblewrap",
        "runtimes" => ["/usr"],
        "environment" => ["LANG"],
        "timeout_ms" => 120_000,
        "max_output_bytes" => 1_048_576,
        "max_concurrent" => 4,
        "max_queue" => 256,
        "queue_timeout_ms" => 120_000
      },
      "policy" => %{"mode" => "allowlist"},
      "agents" => %{"bench" => %{"depth" => 0, "text" => "Wait for the model response."}},
      "tools" => %{"paths" => [Application.app_dir(:omunculus, Path.join("priv", "tools"))]}
    })
  end

  defp fail(agent, reason) do
    emit(%{type: "failure", agent: agent, reason: reason})
    System.halt(2)
  end

  defp emit(event),
    do: IO.puts(Jason.encode!(Map.put(event, :at_us, System.monotonic_time(:microsecond))))
end
