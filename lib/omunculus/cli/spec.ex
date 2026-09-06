defmodule Omunculus.CLI.Spec do
  @moduledoc false
  # Mirrors omunculus.usage.kdl. The KDL file is the portable contract (help,
  # completions, manpages). This module is what the Elixir parser walks.

  def bin, do: "omunculus"
  def about, do: "Coding-agent harness: a directory, an instruction, files change."

  def long_about do
    "Omunculus is a BEAM coding-agent harness. The CLI opens one session against a directory, talks to an OpenAI-compatible chat endpoint, and applies filesystem tools until the model halts. It does not commit, and it does not speak Anthropic Messages."
  end

  def unknown_flags, do: :error
  def default_subcommand, do: "run"
  def arg_required_else_help, do: true

  def exit_codes do
    [
      {0, "session halted without host or chat error"},
      {1, "host, chat, or runtime error"},
      {2, "usage error (bad argv, missing required arg, unknown command)"}
    ]
  end

  def examples do
    [
      {"omunculus run ./fixture \"add a README\"", "Run the agent",
       "Open a session against ./fixture"},
      {"omunculus run ./repo --preset plan \"how is auth wired?\"", "Read-only preset", nil},
      {"omunculus run ./app --tools read,grep,ls \"where is the router?\"", "Tool allowlist", nil}
    ]
  end

  def root_flags do
    [
      flag("verbose",
        long: "verbose",
        short: "v",
        env: "OMUNCULUS_VERBOSE",
        global: true,
        help: "Print every round and tool transition to stderr"
      ),
      flag("help_short", short: "h", action: :help_short, builtin: true, help: "Print help"),
      flag("help_long", long: "help", action: :help_long, builtin: true, help: "Print help"),
      flag("version",
        long: "version",
        short: "V",
        action: :version,
        builtin: true,
        help: "Print version"
      )
    ]
  end

  def commands do
    %{
      "run" => %{
        name: "run",
        about: "Run the agent on a directory",
        long_about:
          "Canonicalize <dir>, load presets from omunculus.toml (project over ~/.omunculus/config.toml), and loop AskModel ↔ tools until halt. Does not commit. Flags override the environment; the environment overrides config; config overrides defaults.",
        arg_required_else_help: true,
        args: [
          %{
            name: :dir,
            metavar: "dir",
            required: true,
            variadic: false,
            help: "Working directory (the worktree)"
          },
          %{
            name: :instruction,
            metavar: "instruction",
            required: true,
            variadic: true,
            var_min: 1,
            help: "What the agent should do"
          }
        ],
        flags: [
          flag("preset",
            long: "preset",
            value: "preset",
            env: "OMUNCULUS_PRESET",
            help: "Named preset from config"
          ),
          flag("tools",
            long: "tools",
            value: "tools",
            delimiter: ",",
            help: "Allowlist of tool names (comma-separated)"
          ),
          flag("model", long: "model", value: "model", env: "OMUNCULUS_MODEL", help: "Model id"),
          flag("max_turns",
            long: "max-turns",
            value: "n",
            default: "32",
            env: "OMUNCULUS_MAX_TURNS",
            help: "Turn budget"
          ),
          flag("base_url",
            long: "base-url",
            value: "url",
            env: "OMUNCULUS_BASE_URL",
            help: "OpenAI-compatible base URL"
          ),
          flag("api_key",
            long: "api-key",
            value: "key",
            env: "OMUNCULUS_API_KEY",
            hide_env_values: true,
            help: "API key"
          ),
          flag("config",
            long: "config",
            value: "file",
            help: "Config file (overrides <dir>/omunculus.toml)"
          ),
          flag("json_events",
            long: "json-events",
            help: "Write one JSON event per line to stderr instead of the TTY reporter"
          )
        ],
        examples: [
          {"omunculus run . \"list the modules in lib/\"", nil, nil},
          {"omunculus run ./app --preset plan \"summarize the FS tools\"", nil, nil}
        ]
      },
      "monkey-job" => %{
        name: "monkey-job",
        about: "Run a diagnostic prompt with an optional tool set",
        long_about:
          "Run the normal agent loop from the current directory while explicitly controlling which tools the model can see and how long tool results remain pending.",
        arg_required_else_help: true,
        args: [
          %{
            name: :instruction,
            metavar: "instruction",
            required: true,
            variadic: true,
            var_min: 1,
            help: "Diagnostic instruction sent to the model unchanged"
          }
        ],
        flags: [
          flag("tools",
            long: "tools",
            value: "tools",
            delimiter: ",",
            help: "Tool names exposed to the model (default: none)"
          ),
          flag("delay", long: "delay", value: "duration", help: "Delay every tool result"),
          flag("increment",
            long: "increment",
            value: "number",
            help: "Counter increment (requires --tools counter)"
          ),
          flag("model", long: "model", value: "model", env: "OMUNCULUS_MODEL", help: "Model id"),
          flag("max_turns",
            long: "max-turns",
            value: "n",
            default: "32",
            env: "OMUNCULUS_MAX_TURNS",
            help: "Round budget"
          ),
          flag("base_url",
            long: "base-url",
            value: "url",
            env: "OMUNCULUS_BASE_URL",
            help: "OpenAI-compatible base URL"
          ),
          flag("api_key",
            long: "api-key",
            value: "key",
            env: "OMUNCULUS_API_KEY",
            hide_env_values: true,
            help: "API key"
          ),
          flag("config",
            long: "config",
            value: "file",
            help: "Config file used for the diagnostic run"
          ),
          flag("json_events",
            long: "json-events",
            help: "Write one JSON event per line to stderr instead of the TTY reporter"
          )
        ],
        examples: [
          {"omunculus monkey-job \"count to 10\"", nil, nil},
          {"omunculus monkey-job \"count to 10\" --tools counter --delay 1s --increment 1", nil,
           nil}
        ]
      },
      "spike" => %{
        name: "spike",
        about: "Run the planned Event Core end to end with a provider-free counting task",
        long_about:
          "Exercises docs/to-be: the instruction enters as a task.requested envelope, Runs are activated from delivered events, delegation builds the tree at runtime, every tool call round-trips through the append-only EVENTS log in SQLite, projections are reduced from the log and rebuilt by replay. No model provider is contacted.",
        arg_required_else_help: true,
        args: [
          %{
            name: :instruction,
            metavar: "instruction",
            required: true,
            variadic: true,
            var_min: 1,
            help: "Counting task, e.g. \"conte até 10\""
          }
        ],
        flags: [
          flag("depth",
            long: "depth",
            value: "n",
            default: "1",
            help: "Delegation depth: 0 counts directly, 1 = scenario 3, 2 = scenario 4"
          ),
          flag("db",
            long: "db",
            value: "file",
            help: "SQLite file for EVENTS and projections (default: temporary file)"
          ),
          flag("fail_at",
            long: "fail-at",
            value: "n",
            help: "Kill the counting worker after it reaches n, then resume it as a new attempt"
          ),
          flag("delay", long: "delay", value: "duration", help: "Delay every tool result"),
          flag("json_events",
            long: "json-events",
            help: "Write the ordered EVENTS log as one JSON envelope per line to stderr"
          )
        ],
        examples: [
          {"omunculus spike \"conte até 10\" --depth 2", nil, nil},
          {"omunculus spike \"conte até 10\" --fail-at 3 --delay 50ms", nil, nil}
        ]
      },
      "benchmark" => %{
        name: "benchmark",
        about: "Measure concurrent actors, resident agent trees, or HTTP load",
        long_about:
          "actor-density measures a provider-free Agent state plateau in the current BEAM runtime. agent-tree is a synthetic provider-free resident tree stress benchmark: nodes are created in waves and ancestors remain blocked at round_started. http-load drives the external Rust stub through a dedicated Finch pool. RSS and CPU scheduler limits are soft benchmark controls; --cpu-limit changes BEAM schedulers_online only and is restored after the run, not a cgroup or physical CPU quota. Durable trees are documented in docs/to-be/execution-model.md and are not implemented.",
        arg_required_else_help: false,
        args: [],
        flags: [
          flag("scenario",
            long: "scenario",
            value: "scenario",
            default: "actor-density",
            help: "Scenario: actor-density, agent-tree, or http-load"
          ),
          flag("max_agents",
            long: "max-agents",
            value: "n",
            help: "Maximum actor-density level target"
          ),
          flag("max_trees",
            long: "max-trees",
            value: "n",
            help: "Maximum resident agent-tree count"
          ),
          flag("tree_shape",
            long: "tree-shape",
            value: "widths",
            default: "1,1,2,4",
            help: "Agent-tree widths by depth (positive multiples)"
          ),
          flag("tree_mode",
            long: "tree-mode",
            value: "mode",
            default: "resident",
            help:
              "Agent-tree mode: resident (durable is documented in docs/to-be/execution-model.md)"
          ),
          flag("memory_limit",
            long: "memory-limit",
            value: "size",
            help: "Soft RSS ceiling (K/M/G, base 1024)"
          ),
          flag("provider",
            long: "provider",
            value: "provider",
            default: "stub",
            help: "Provider for config validation: stub or real"
          ),
          flag("model", long: "model", value: "model", help: "Model id override"),
          flag("tools",
            long: "tools",
            value: "tools",
            default: "none",
            help: "Tools: none or counter"
          ),
          flag("rounds", long: "rounds", value: "n", default: "1", help: "Agent round budget"),
          flag("stub_delay_ms",
            long: "stub-delay-ms",
            value: "n",
            default: "0",
            help: "Stub response delay in milliseconds"
          ),
          flag("payload_bytes",
            long: "payload-bytes",
            value: "n",
            default: "0",
            help: "Instruction/request payload size"
          ),
          flag("step",
            long: "step",
            value: "n",
            help: "Linear ramp increment; tree ramps by trees"
          ),
          flag("sample_ms",
            long: "sample-ms",
            value: "n",
            default: "100",
            help: "RSS sampling interval"
          ),
          flag("http_concurrency",
            long: "http-concurrency",
            value: "n",
            default: "1",
            help: "Dedicated HTTP pool size"
          ),
          flag("cpu_limit",
            long: "cpu-limit",
            value: "n",
            help: "Soft BEAM schedulers_online limit (restored after run)"
          ),
          flag("live", long: "live", help: "Render live progress when attached to a TTY"),
          flag("no_live", long: "no-live", help: "Use append-only progress"),
          flag("json", long: "json", value: "path", help: "Write the final summary as JSON")
        ],
        examples: [
          {"omunculus benchmark --max-agents 8", "Provider-free actor density", nil},
          {"omunculus benchmark --scenario agent-tree --max-trees 4 --tree-shape 1,1,2,4",
           "Synthetic resident agent tree", nil},
          {"omunculus benchmark --scenario http-load --max-agents 32 --http-concurrency 8",
           "Dedicated Finch HTTP load", nil},
          {"omunculus benchmark --memory-limit 512M --cpu-limit 2",
           "Soft RSS and scheduler limits", nil}
        ]
      },
      "help" => %{
        name: "help",
        about: "Print this message or the help of the given subcommand(s)",
        long_about: nil,
        arg_required_else_help: false,
        args: [
          %{
            name: :command,
            metavar: "command",
            required: false,
            variadic: false,
            help: "Command to describe"
          }
        ],
        flags: [],
        examples: []
      }
    }
  end

  def command(name), do: Map.get(commands(), name)

  def flag(name, opts) do
    %{
      name: name,
      long: Keyword.get(opts, :long),
      short: Keyword.get(opts, :short),
      value: Keyword.get(opts, :value),
      env: Keyword.get(opts, :env),
      default: Keyword.get(opts, :default),
      delimiter: Keyword.get(opts, :delimiter),
      global: Keyword.get(opts, :global, false),
      action: Keyword.get(opts, :action),
      builtin: Keyword.get(opts, :builtin, false),
      hide_env_values: Keyword.get(opts, :hide_env_values, false),
      help: Keyword.get(opts, :help)
    }
  end
end
