Status: AS-IS — implementado

# Modelo de dados atual

Na branch `spike/event-core` coexistem estado transitório (`run`/`monkey-job`) e
persistência SQLite/WAL no caminho Event Core (`spike`, `emit`, `events follow`).
A arquitetura está em [architecture.md](architecture.md); o alvo separado em
[TO-BE data model](../to-be/data-model.md).

## Envelope

Cada linha de `EVENTS` e cada notificação `{:event_core, _}` usam
`Omunculus.Event.Envelope`:

- `event_id`, `kind` (`command`|`event`), `type`, `schema_version`, `sequence`
  (atribuído no append), `occurred_at`
- `correlation_id`, `causation_id`, `idempotency_key`
- `session_id`, `workspace_id` (reservados, geralmente nil)
- `project_id`, `work_item_id`, `run_id`
- `payload` (mapa JSON)

`Omunculus.Events` rejeita tipo desconhecido, kind incorreto, versão de schema
não registrada ou campos obrigatórios ausentes.

## Tabelas SQLite

| Tabela | Função |
|---|---|
| `EVENTS` | Log append-only; fonte de verdade |
| `WORK_ITEMS` | Projeção: instrução, status, checkpoint, awaiting, result, version, last_sequence |
| `WORK_ITEM_DEPENDENCIES` | Projeção: dependência pai→filho criada por `task.delegated` |
| `ARCHIVE_RUNS` | Projeção: attempt, depth, parent_run_id, originating_run_id, agent_id, agent_kind, status, reason, outcome |
| `ARCHIVE_MODEL_CALLS` | Projeção: round, model, usage, outcome por `model.call.completed` |
| `PROJECTION_CURSORS` | Checkpoint por consumidor (`domain`, `automation:<name>`) |
| `PROJECTS` | Esquema presente; spike não popula |
| `COMMENTS` | Esquema presente; sem escritores no runtime atual |

`Projector` aplica eventos após o cursor em transação atômica com avanço do
cursor. Redelivery do mesmo `event_id` ou `last_sequence` defasado é no-op.
`rebuild/1` apaga projeções e reexecuta o log inteiro.

## O que cada tipo escreve

| Tipo | Efeito principal |
|---|---|
| `task.requested` | Novo WI; ativa Run depth 0 |
| `task.resumed` | Novo Run `reason=retry` se WI failed |
| `task.delegated` | Filho WI + dependência; ativa Run filho |
| `task.completed` | WI `completed` + result; pode continuar pai |
| `task.resume_rejected` | Sem novo Run |
| `tool.call.requested` | (interceptável; sem projeção de domínio) |
| `tool.call.completed` | Atualiza checkpoint no Run |
| `run.started` | Linha `ARCHIVE_RUNS`; fixa tools e team no payload |
| `run.completed` | Fecha run; `outcome` inclui `waiting` + awaiting |
| `run.failed` | WI elegível a resume |
| `model.call.completed` | Linha `ARCHIVE_MODEL_CALLS` |
| `policy.loaded` | Hash da policy ativa (snapshot opcional) |
| `delivery.rejected` | Registro de bloqueio; envelope original permanece |

## Estado transitório (`run`)

`Agent.run/1` mantém em memória `messages`, dependências (`chat`, `context`,
`tools`, `schemas`), `turn`/`max_turns`, `usage`, `reporter`. Nada é reaberto
entre invocações.

`Config` normaliza TOML para `defaults`, `chat`, `output`, `presets`, mais
`agents`, `teams`, `workspaces`, `policy`, `session`, `interceptors`,
`automations`.

## Runtime in-memory

O processo `Omunculus.Runtime` guarda `runs`, `pids`, `handled` (dedupe de
entrega) e `pending_continuations` (mapa work_item_id → continuação do pai).
`pending_continuations` não sobrevive a restart do Runtime.

Cada `Run` é um GenServer temporário com checkpoint
(`messages`, `tool_state`, `pending`, `notes`, `awaiting`).

## O que não é registro ativo

- Inbox humana em `COMMENTS`
- Eventos de sessão/workspace (`session.created`, `workspace.attached`)
- Eventos de permissão (`permission.*`)
- Grants temporários ou permanentes fora do payload de `run.started.tools`

A separação planejada desses conceitos está em
[execution-model.md](../to-be/execution-model.md) e documentos TO-BE correlatos.
