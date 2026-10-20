# Omunculus compared with DeepSeek Harness, OpenCode v2 and Hermes Agent

The Omunculus column was checked against this tree on 2026-10-13. The other
three are as of 2026-10-08: DeepSeek Harness 0.2.1-alpha.1, OpenCode v2.0.24
and Hermes Agent v0.21.5, read from their repositories and documentation.

Legend: **P** shipped · **T** a tool, hook or API client the architecture
supports, not written yet · **K** needs a change in the harness core ·
**—** unnecessary by design · **✗** not supported · **?** not verified

| Area | Feature | Omunculus | DeepSeek Harness | OpenCode v2 | Hermes Agent |
|---|---|---|---|---|---|
| **Architecture** | Thesis | Orchestration kernel: fixed guarantees, everything else is a tool | Framework: everything is a plugin | Coding agent product | Personal agent that learns |
| | What is fixed | Only the guarantees: `end` ends a run, ceiling, store rules, sandbox | Nothing | Loop, permissions, storage | `AIAgent` loop |
| | Configurable loop/cycle | **P** workflow on/off per policy and depth, stages, `overrides`, hooks with `agent`, replaceable `assemble` | **P** (the loop is a plugin) | ◐ agents, `steps` | ◐ `max_turns`, `/goal`, `/loop` |
| | Guarantees no extension can disable | **P** | ✗ | ◐ | ◐ |
| | Replaceable builtin tools | **P** all, by name | **P** | **P** | ◐ with double opt-in |
| | Extension language | **P** any (JSON on stdin/stdout) | TS | TS | Python; others through MCP or shell |
| | Extensions emit transactional state | **P** `emit` → store | ◐ `ctx` | ✗ | ✗ |
| | Sandboxed extensions | **P** always, MCP included | ✗ | ✗ | ◐ separate process |
| | Self-modification (agent, workflow, tools, prompt) | **P** as a permission, off by default | ◐ Creator preset | ✗ | ◐ skills and memory |
| | Config applied without restart | **P** reloaded on every run | **P** HMR | **P** | ◐ |
| **Governance** | Work tree with state in the store | **P** | ✗ | ✗ | ◐ kanban |
| | Ceiling per stage | **P** | ✗ | ◐ plan agent | ✗ |
| | Requests with a hierarchical arbiter | **P** | ✗ | ✗ | ✗ |
| | Deterministic guardrail | **P** a call outside the ceiling does not exist | ◐ | ◐ rules | ◐ regex + LLM judge |
| | Persistent scoped grants | **P** TOML per layer | ✗ | **P** | **P** allowlist |
| | Multiple users, roles, IdP | **P** capabilities + JWT | ✗ | ✗ | ◐ |
| | Multiple projects and workspaces | **P** registry + workspaces with their own model and ceiling | ◐ | **P** | **P** profiles |
| | Decisions recorded as data | **P** requests, options, arbiter, grants | ◐ approval log | ◐ | ◐ logs |
| **Interfaces** | CLI / API / real time | **P** / **P** OpenAPI / **P** WebSocket | **P** / ◐ / **P** | **P** / **P** / **P** | **P** / **P** / **P** SSE |
| | Messaging channels | **T** events + hooks; requests become buttons | ✗ | ✗ | **P** ~25 |
| | IDE (ACP) | **T** | **P** | **P** | **P** |
| | Installation | ◐ checkout + mise | **P** npm | **P** brew/npm | **P** |
| **Models** | Providers | **P** 3 protocols + **T** through `command` | ◐ | **P** 226 | **P** 40+ |
| | Prompt caching | **P** stable prefix, `prompt_cache_key`, Anthropic `cache_control` breakpoints | **P** | **P** | **P** |
| | Tokens and cost | **P** every HTTP adapter records `usage`; `runs` sums tokens and cost | **P** | **P** | **P** |
| **Tools for the model** | Code mode | **P** with a model's `code_mode`, every tool | **P** `ptc` | **P** MCP and plugins | ◐ 7 tools |
| | On-demand schemas | ◐ `tool_search`/`pinned` exist; every schema is sent (**K**) | ✗ | **P** | **P** |
| | MCP | **P** inside the sandbox | **P** | **P** | **P** |
| **Context** | Context per run | **P** rebuilt each run: agent, tools, work, goal, last comment, last run; or a paused session continued (`session_ttl_ms`) | Accumulated session | Accumulated session | Accumulated session |
| | Compaction | ◐ a session past `session_max_bytes` starts over with fresh context; `compact_comments` | **P** | **P** | **P** |
| | Tool output cut | **P** whole output kept in the event | **P** | **P** | **P** |
| | History search beyond the last run | ◐ through comments and reports; deeper search needs a new view (**K**) | **P** | **P** | **P** FTS5 |
| | Long-term memory / skills | ◐ Agent Skills (`[skills] paths`, `skill`); no memory | ◐ | ◐ | **P** |
| **Coding: reading** | Read with offset/limit | **P** | **P** | **P** | **P** |
| | Image / PDF | **T** | **P** | **P** | **P** |
| | Grep / find | **P** `grep` and `find` leave out `.git` and what `.gitignore` ignores | **P** | **P** | **P** |
| | LSP | **T** | **P** | ✗ | ✗ |
| **Coding: editing** | Exact, unique replacement | **P** | **P** | **P** | **P** |
| | Multi-edit, patch, diff, read before edit | ◐ per-call diff through `changes`; **T** multi-edit and patch | **P** | **P** | **P** |
| | Formatter after edit | **T** hook | ? | **P** | ? |
| **Coding: execution** | Shell | ◐ new `sh -c` per call (codex-like preset) | **P** persistent | **P** | **P** persistent |
| | Background processes | **—** event-driven | **P** | **P** | **P** |
| | Timeout | ◐ one `timeout_ms` for everything | **P** | **P** | **P** |
| | Network for dependencies | **P** through a `sandbox.network` grant | ◐ | **P** uncontrolled | **P** |
| | Per-call latency | ◐ Bubblewrap (+ Deno) per call | Persistent process | On the host | Persistent process |
| | Backends / platform | ◐ Bubblewrap and Linux only (**K**) | **P** | **P** | **P** 7 backends |
| **Coding: flow** | Plan → implement → review with distinct permissions | **P** workflow | ◐ | ◐ | ◐ |
| | One model per stage and per workspace | **P** | ◐ | ◐ | ◐ |
| | The agent cannot quit silently | **P** retry → break or request | ◐ goals | ✗ | ◐ `/goal` |
| | Parallel subagents | **P** works + `max_concurrent` | **P** | **P** | **P** |
| | Isolated writers (worktree) | **T** deterministic: the tool opens the worktree when the run starts and merges into the parent branch when it ends | ? | ◐ plugin | ✗ |
| | Message during a run | ◐ goes to the work's next run | **P** | **P** | **P** |
| | Undo / checkpoints | **P** `changes` records each call's files; `revert` puts a work's back | ◐ fork | **P** git | **P** `/rollback` |
| | Reply shown on the CLI | **T** (`send` prints nothing today) | **P** | **P** | **P** |
| **Extras** | Web search / browser / scheduling | **T** | **P** / ✗ / **P** | **P** / ◐ / ✗ | **P** / **P** / **P** |

## Remaining gaps

Core changes (**K**):

- on-demand schemas (send only `pinned`, `tool_search` returns the rest)
- a deeper history view, for search beyond the last run
- execution outside Linux and Bubblewrap

Tools and hooks (**T**), a `coding` package for the presets: multi-edit and
patch, reply on the CLI, worktree per run, formatter, LSP, image and PDF
reading. For reach: a messaging channel and web search.

## Sources

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- [anomalyco/opencode v2.0.24](https://github.com/anomalyco/opencode/tree/v2.0.24)
- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) and [its docs](https://hermes-agent.nousresearch.com/docs)
- [opencode issue #49645](https://github.com/anomalyco/opencode/issues/49645)
- [OpenChamber: OpenCode v2](https://openchamber.dev/blog/opencode-v2/)
- [DeepInfra: DeepSeek Harness review](https://deepinfra.com/blog/deepseek-harness-review)
