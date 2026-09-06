defmodule Omunculus.CLI do
  @moduledoc false

  alias Omunculus.CLI.{Help, Parser}
  alias Omunculus.Dotenv

  def main(argv) do
    :ok = Omunculus.Native.ensure_nif!()
    {:ok, _} = Application.ensure_all_started(:omunculus)
    System.halt(dispatch(argv))
  end

  def dispatch(argv, env \\ System.get_env()) do
    case Parser.parse(argv, env) do
      {:ok, %{command: :version}} ->
        IO.puts(Omunculus.version())
        0

      {:ok, %{command: :help} = parsed} ->
        print_help(parsed)

      {:ok, %{command: :run} = parsed} ->
        run_with_dotenv(argv, parsed, env)

      {:ok, %{command: :benchmark} = parsed} ->
        run_with_dotenv(argv, parsed, env)

      {:ok, %{command: :"monkey-job"} = parsed} ->
        run_with_dotenv(argv, parsed, env)

      {:ok, %{command: :spike} = parsed} ->
        Omunculus.CLI.Spike.run(parsed, env)

      {:error, reason} ->
        IO.puts(:stderr, Help.usage_error(reason))
        2
    end
  end

  defp run_with_dotenv(argv, parsed, env) do
    dir = parsed.args[:dir] || File.cwd!()

    with {:ok, file_env} <- Dotenv.load(dir),
         merged_env = Map.merge(file_env, env),
         {:ok, parsed} <- Parser.parse(argv, merged_env) do
      dispatch_run(parsed, merged_env)
    else
      {:error, reason} ->
        IO.puts(:stderr, "error: #{format_error(reason)}")
        1
    end
  end

  defp dispatch_run(%{command: :run} = parsed, env), do: run(parsed, env)
  defp dispatch_run(%{command: :"monkey-job"} = parsed, env), do: monkey_job(parsed, env)
  defp dispatch_run(%{command: :benchmark} = parsed, env), do: benchmark(parsed, env)

  defp benchmark(%{flags: flags}, env) do
    with {:ok, opts} <- parse_benchmark(flags, env),
         {:ok, reporter} <- start_benchmark_reporter(opts) do
      result =
        Omunculus.Benchmark.run(
          Map.put(opts, :reporter, &Omunculus.CLI.BenchmarkReporter.event(reporter, &1))
        )

      _ = Omunculus.CLI.BenchmarkReporter.stop(reporter)

      case result do
        {:ok, _} ->
          0

        {:error, {:usage, reason}} ->
          IO.puts(:stderr, Help.usage_error(reason))
          2

        {:error, reason} ->
          IO.puts(:stderr, "error: #{format_error(reason)}")
          1
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, Help.usage_error(reason))
        2
    end
  end

  defp start_benchmark_reporter(opts) do
    live? =
      case opts[:live] do
        true -> true
        false -> false
        _ -> IO.ANSI.enabled?()
      end

    Omunculus.CLI.BenchmarkReporter.start_link(
      io: :stderr,
      live?: live?,
      runtime: :current_runtime,
      width: 80
    )
  end

  defp parse_benchmark(flags, env) do
    with {:ok, max_agents} <- parse_optional_positive(flags["max_agents"], :max_agents),
         {:ok, max_trees} <- parse_optional_positive(flags["max_trees"], :max_trees),
         {:ok, memory_limit} <- parse_memory(flags["memory_limit"]),
         {:ok, rounds} <- parse_positive_flag(flags["rounds"] || "1", :rounds),
         {:ok, delay} <- parse_nonnegative_flag(flags["stub_delay_ms"] || "0", :stub_delay_ms),
         {:ok, payload} <- parse_nonnegative_flag(flags["payload_bytes"] || "0", :payload_bytes),
         {:ok, step} <- parse_optional_positive(flags["step"], :step),
         {:ok, sample} <- parse_positive_flag(flags["sample_ms"] || "100", :sample_ms),
         {:ok, http_concurrency} <-
           parse_positive_flag(flags["http_concurrency"] || "1", :http_concurrency),
         {:ok, cpu_limit} <- parse_optional_positive(flags["cpu_limit"], :cpu_limit),
         {:ok, tree_shape} <- parse_tree_shape(flags["tree_shape"] || "1,1,2,4") do
      provider = flags["provider"] || "stub"
      tools = flags["tools"] || "none"
      scenario = flags["scenario"] || "actor-density"

      if scenario == "agent-tree" and is_nil(max_trees) and is_nil(memory_limit) do
        {:error, {:benchmark_tree_limit_required, nil}}
      else
        {:ok,
         %{
           scenario: scenario,
           tree_mode: flags["tree_mode"] || "resident",
           tree_shape: tree_shape,
           max_agents: max_agents,
           max_trees: max_trees,
           memory_limit: memory_limit,
           provider: provider,
           model: flags["model"] || env["OMUNCULUS_MODEL"],
           tools: tools,
           rounds: rounds,
           stub_delay_ms: delay,
           payload_bytes: payload,
           step: step,
           sample_ms: sample,
           http_concurrency: http_concurrency,
           cpu_limit: cpu_limit,
           live:
             cond do
               flags["no_live"] -> false
               flags["live"] -> true
               true -> nil
             end,
           json: flags["json"],
           cwd: File.cwd!(),
           config: flags["config"],
           env: env
         }}
      end
    end
  end

  defp parse_tree_shape(raw) when is_binary(raw) do
    values = String.split(raw, ",", trim: false)

    parsed =
      Enum.reduce_while(values, [], fn value, acc ->
        case Integer.parse(String.trim(value)) do
          {number, ""} when number > 0 -> {:cont, [number | acc]}
          _ -> {:halt, :error}
        end
      end)

    case parsed do
      :error ->
        {:error, {:invalid_tree_shape, raw}}

      [] ->
        {:error, {:invalid_tree_shape, raw}}

      values ->
        values = Enum.reverse(values)

        if hd(values) == 1 and
             Enum.all?(Enum.chunk_every(values, 2, 1, :discard), fn [a, b] ->
               rem(b, a) == 0
             end),
           do: {:ok, values},
           else: {:error, {:invalid_tree_shape, raw}}
    end
  end

  defp parse_tree_shape(raw), do: {:error, {:invalid_tree_shape, raw}}

  defp parse_positive_flag(raw, name), do: parse_integer_flag(raw, name, 1)
  defp parse_nonnegative_flag(raw, name), do: parse_integer_flag(raw, name, 0)
  defp parse_optional_positive(nil, _name), do: {:ok, nil}
  defp parse_optional_positive(raw, name), do: parse_integer_flag(raw, name, 1)

  defp parse_integer_flag(raw, name, minimum) when is_integer(raw) do
    if raw >= minimum,
      do: {:ok, raw},
      else: {:error, {String.to_atom("invalid_" <> Atom.to_string(name)), raw}}
  end

  defp parse_integer_flag(raw, name, minimum) when is_binary(raw) do
    case Integer.parse(raw) do
      {value, ""} when value >= minimum -> {:ok, value}
      _ -> {:error, {String.to_atom("invalid_" <> Atom.to_string(name)), raw}}
    end
  end

  defp parse_integer_flag(raw, name, _minimum),
    do: {:error, {String.to_atom("invalid_" <> Atom.to_string(name)), raw}}

  defp parse_memory(nil), do: {:ok, nil}

  defp parse_memory(raw) when is_binary(raw) do
    case Regex.run(~r/^(\d+)([KMG])?$/i, raw) do
      [_, number] ->
        {:ok, String.to_integer(number)}

      [_, number, unit] ->
        multiplier =
          %{"K" => 1_024, "M" => 1_024 * 1_024, "G" => 1_024 * 1_024 * 1_024}[String.upcase(unit)]

        {:ok, String.to_integer(number) * multiplier}

      _ ->
        {:error, {:invalid_memory_limit, raw}}
    end
  end

  defp parse_memory(raw), do: {:error, {:invalid_memory_limit, raw}}

  defp monkey_job(%{args: args, flags: flags}, env) do
    tools = flags["tools"] || []

    with {:ok, delay_ms} <- parse_duration(flags["delay"]),
         {:ok, increment} <- parse_increment(flags["increment"], tools) do
      flags =
        flags
        |> Map.put("tools", tools)
        |> Map.put(:tool_options, %{
          delay_ms: delay_ms,
          tools: %{"counter" => %{increment: increment}}
        })

      instruction = monkey_instruction(args.instruction, tools)

      case Omunculus.Runner.start(%{dir: File.cwd!(), instruction: instruction}, flags, env) do
        {:ok, result} ->
          unless flags["json_events"] do
            print_monkey_summary(result, tools, delay_ms, increment)
          end

          text = result.assistant_text || ""
          if text != "", do: IO.puts(text)
          0

        {:error, reason} ->
          IO.puts(:stderr, "error: #{format_error(reason)}")
          1
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, Help.usage_error(reason))
        2
    end
  end

  defp monkey_instruction(instruction, tools) do
    if "counter" in tools do
      """
      #{instruction}

      This is not a coding task. Use only the counter tool. Call it once per increment until the tool returns the number the user asked you to count to. Do not count in prose. After the target value, stop.
      """
    else
      instruction
    end
  end

  defp parse_duration(nil), do: {:ok, 0}

  defp parse_duration(raw) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)(ms|s)?$/, raw) do
      [_, value, "ms"] ->
        {:ok, round(String.to_float(normalize_float(value)))}

      [_, value, unit] when unit in ["", "s"] ->
        {:ok, round(String.to_float(normalize_float(value)) * 1_000)}

      _ ->
        {:error, {:invalid_delay, raw}}
    end
  end

  defp normalize_float(value),
    do: if(String.contains?(value, "."), do: value, else: value <> ".0")

  defp parse_increment(nil, _tools), do: {:ok, 1}

  defp parse_increment(raw, tools) do
    if "counter" in tools do
      case Integer.parse(raw) do
        {value, ""} when value != 0 -> {:ok, value}
        _ -> {:error, {:invalid_increment, raw}}
      end
    else
      {:error, {:option_requires_tool, "--increment", "counter"}}
    end
  end

  defp print_monkey_summary(result, tools, delay_ms, increment) do
    counter = result.tool_state["counter"] || %{value: 0, calls: 0}
    exposed = if tools == [], do: "none", else: Enum.join(tools, ",")

    IO.puts(:stderr, "")
    IO.puts(:stderr, "┌───────────────────┬──────────────┐")
    IO.puts(:stderr, "│ Monkey metric     │ Value        │")
    IO.puts(:stderr, "├───────────────────┼──────────────┤")
    monkey_row("Exposed tools", exposed)
    monkey_row("Tool calls", result.tool_calls)
    if "counter" in tools, do: monkey_row("Counter value", counter.value)
    if "counter" in tools, do: monkey_row("Counter increment", increment)
    monkey_row("Delay", format_delay(delay_ms))
    IO.puts(:stderr, "└───────────────────┴──────────────┘")
  end

  defp monkey_row(label, value),
    do:
      IO.puts(
        :stderr,
        "│ #{String.pad_trailing(label, 17)} │ #{String.pad_trailing(to_string(value), 12)} │"
      )

  defp format_delay(ms) when rem(ms, 1_000) == 0, do: "#{div(ms, 1_000)}s"
  defp format_delay(ms), do: "#{ms}ms"

  defp print_help(%{target: target, style: style} = parsed) do
    case Help.render(target, style) do
      {:ok, text} ->
        IO.write(text)
        if Map.get(parsed, :else_help), do: 2, else: 0

      {:error, reason} ->
        IO.puts(:stderr, Help.usage_error(reason))
        2
    end
  end

  defp run(%{args: args, flags: flags}, env) do
    case Omunculus.Runner.start(args, flags, env) do
      {:ok, result} ->
        text = result.assistant_text || ""
        if text != "", do: IO.puts(text)
        0

      {:error, {:usage, reason}} ->
        IO.puts(:stderr, Help.usage_error(reason))
        2

      {:error, reason} ->
        IO.puts(:stderr, "error: #{format_error(reason)}")
        1
    end
  end

  defp format_error({:chat, reason}), do: "chat failed: #{inspect(reason)}"
  defp format_error({:host, reason}), do: "host failed: #{inspect(reason)}"
  defp format_error({:unsupported_api, api}), do: "unsupported chat api #{inspect(api)}"
  defp format_error({:unsupported_auth, type}), do: "unsupported auth #{inspect(type)}"
  defp format_error({:unknown_preset, name}), do: "unknown preset #{inspect(name)}"
  defp format_error({:unknown_tool, name}), do: "unknown tool #{inspect(name)}"
  defp format_error({:path_escape, path}), do: "path escapes worktree: #{path}"

  defp format_error({:stub_unavailable, reason}),
    do: "benchmark stub unavailable: #{inspect(reason)}"

  defp format_error({:stub_exit, status}), do: "benchmark stub exited with status #{status}"
  defp format_error(:stub_timeout), do: "benchmark stub did not become ready"

  defp format_error({:benchmark_limit_required, _}),
    do: "benchmark requires --max-agents or --memory-limit"

  defp format_error({:invalid_memory_limit, raw}), do: "invalid --memory-limit #{inspect(raw)}"
  defp format_error({:invalid_max_agents, raw}), do: "invalid --max-agents #{inspect(raw)}"
  defp format_error({:invalid_provider, raw}), do: "invalid --provider #{inspect(raw)}"
  defp format_error({:invalid_max_turns, raw}), do: "invalid --max-turns #{inspect(raw)}"
  defp format_error({:missing_model, _}), do: "missing --model / OMUNCULUS_MODEL"
  defp format_error({:missing_base_url, _}), do: "missing --base-url / OMUNCULUS_BASE_URL"
  defp format_error({:dotenv, reason}), do: "could not read .env: #{inspect(reason)}"
  defp format_error({:invalid_dotenv, line}), do: "invalid .env entry on line #{line}"

  defp format_error({:invalid_timestamp_format, format}),
    do: "invalid output timestamp format #{inspect(format)}"

  defp format_error({:missing_config_env, name}),
    do: "environment variable #{name} referenced by config is not defined"

  defp format_error({:benchmark_tree_limit_required, _}),
    do: "agent-tree requires --max-trees or --memory-limit"

  defp format_error({:invalid_max_trees, raw}), do: "invalid --max-trees #{inspect(raw)}"
  defp format_error({:invalid_tree_shape, raw}), do: "invalid --tree-shape #{inspect(raw)}"

  defp format_error({:invalid_tree_mode, mode}),
    do:
      "invalid --tree-mode #{inspect(mode)} (durable is documented in docs/to-be/execution-model.md)"

  defp format_error(reason), do: inspect(reason)
end
