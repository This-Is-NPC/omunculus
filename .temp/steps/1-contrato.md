# Etapa 1 — Contrato e despacho

Fecha o ciclo mínimo: binário despacha `name`, tool `send` abre a primeira run, o modelo vê `assembled` e termina.

**Aceite:** `D0-H0-W0` sem work. Message → `EVENTS(prompt)` → run → `end-run`. Trocar a pasta `send` não abre o núcleo.

## Plano

1. Descobrir pastas `<builtin>/tools`, `~/.omunculus/tools`, `<projeto>/tools`. Mesmo `name`: o mais específico ganha.
2. Contrato único: `in { name, args, view, run_id, work_id, workspace, roots }` → `out { ok, output, emit }`.
3. CLI é o mesmo contrato. `omunculus send "…"` acha `name = send`, `triggers` inclui `cli`.
4. Action `prompt`: `PROMPTS(kind = message)` + `EVENTS(prompt)` + abre a primeira run.
5. Abrir run: ler TOML agora, `assembled` (agent text + message + cards), `PROMPTS(kind = assembled)`, `RUNS`, `EVENTS(start-run)` → modelo → `EVENTS(model)` → `end-run`.
6. Sem work. Sem ceiling real: catálogo desta etapa = o que o TOML do agent depth 0 listar, ou tudo que tiver `triggers = model` no default mínimo.
7. Modelo fake. Sandbox expõe `tools.<name>(args)` — cada call é uma ida ao contrato.

## Implementação

### Núcleo

- Parser de `tool.toml` / `hook.toml`: `name`, `kind`, `shape`, `triggers`, `description`, `tags`, `groups`, `command`, `parameters`, `views`, `events` (hook).
- Invoke: spawn `command` com JSON no stdin, JSON no stdout. Módulo Elixir default vale se devolver o mesmo `out`.
- `view` vazio se o manifesto não pediu função. Hidratar só o declarado.
- `emit` fora do catálogo ou do schema = tool falhou; nada grava.
- Action `prompt` (efeito completo): message, event, preparar run do agent depth 0 (`concierge` no default).
- Assemble mínimo: agent text + message desta abertura + cards (`name` + description ≤3 linhas). Sem title, sem comment.
- `RUNS.tools` = lista efetiva desta etapa (pode ser “todas as discovered com trigger model”). Remount de verdade é etapa 3.
- Sandbox: uma linguagem, fixa. `tools.send` não entra no assembled (só `cli`).
- Encerrar run: `EVENTS(end-run)`, `status = done`. Nenhum processo fica à espera.

Default TOML: um agent `concierge` depth 0, sem workflow, sem hook.

### Pasta

```text
tools/send/tool.toml    triggers = ["cli"]
tools/send/run          emit { type = "prompt", body = { message } }
```

Schema da tool `send`: a message. Não cria work. Não copia message para title.

### Testes

- `omunculus send "conte até 5"` → 1 `PROMPTS` message, 1 `EVENTS(prompt)`, 1 run `done`, 1 `assembled` ligado a `RUNS.prompt_id`.
- Replay da run: `start-run`, `model`, `end-run` (e `tool` se o fake chamar algo).
- Pasta do projeto no mesmo `name` substitui o `send` builtin; o núcleo não muda.
- Tool com `emit` inválido: nada persiste.
- Segunda abertura não reusa o `assembled` velho — grava outro.

## Não fazer

- `work`, `comment`, `continue`, inbox, request, hook que abre run.
- MCP. Composite. `tool_search` obrigatório (cards podem ser a lista toda).
- Copiar message para `WORKS.title`.

## Pronto quando

Uma message sobe uma run de depth 0 e o replay mostra prompt → start-run → model → end-run.
