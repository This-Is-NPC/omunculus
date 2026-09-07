Status: AS-IS — implementado

# Modelo de dados atual

Na branch `master` coexistem estado transitório (`monkey-job`) e
persistência SQLite/WAL no caminho Event Core (`spike`, `emit`, `events follow`,
`session`, `workspace`, `send`, `inbox`, `run` efêmero). A arquitetura está em
[architecture.md](architecture.md); o alvo separado em
[TO-BE data model](../to-be/data-model.md).

## Envelope

Cada linha de `EVENTS` e cada notificação `{:event_core, _}` usam
`Omunculus.Event.Envelope`:

- `event_id`, `kind` (`command`|`event`), `type`, `schema_version`, `sequence`
  (atribuído no append), `occurred_at`
- `correlation_id`, `causation_id`, `idempotency_key`
- `session_id`, `workspace_id` — preenchidos em sessões duráveis e no `run`
  efêmero; depth 0 costuma ter `workspace_id` nil e workspace no payload;
  depth ≥ 1 replica workspace em `workspace_id`
- `project_id`, `work_item_id`, `run_id`
- `payload` (mapa JSON)

`Omunculus.Events` rejeita tipo desconhecido, kind incorreto, versão de schema
não registrada ou campos obrigatórios ausentes. Catálogo de sessão inclui
`session.created`, `workspace.attached`, `workspace.detached`, `task.commented`,
`permission.requested`, `permission.granted`, `permission.denied`,
`permission.revoked`, `policy.changed`, `inbox.read` (injetáveis onde marcado).

## Tabelas SQLite

Store `user_version` 3 (`COMMENTS.read_at`).

| Tabela | Função |
|---|---|
| `EVENTS` | Log append-only; fonte de verdade |
| `WORK_ITEMS` | Projeção: instrução, status, checkpoint, awaiting, result, `workspace_id`, version, last_sequence |
| `SESSION_WORKSPACES` | Projeção: `workspace_id` PK, roots, teams, attached, attached_at, last_sequence — reduzida de `workspace.attached` / `workspace.detached` |
| `WORK_ITEM_DEPENDENCIES` | Projeção: dependência pai→filho criada por `task.delegated` |
| `ARCHIVE_RUNS` | Projeção: attempt, depth, parent_run_id, originating_run_id, agent_id, agent_kind, status, reason, outcome |
| `ARCHIVE_MODEL_CALLS` | Projeção: round, model, usage, outcome por `model.call.completed` |
| `PROJECTION_CURSORS` | Checkpoint por consumidor (`domain`, `automation:<name>`) |
| `PROJECTS` | Esquema presente; spike não popula |
| `COMMENTS` | Projeção: `comment_id`, `session_id`, `work_item_id`, kind, body, `read_at`, `event_id`, last_sequence |

`COMMENTS.kind`:

- `request` — de `permission.requested` ou `task.commented`
- `response` — de `permission.granted`, `permission.denied` ou `task.commented`
- `result` — de `task.completed`

`inbox.read` preenche `read_at` na linha correspondente (`comment_id` ou
`event_id`).

`Projector` aplica eventos após o cursor em transação atômica com avanço do
cursor. Redelivery do mesmo `event_id` ou `last_sequence` defasado é no-op.
`rebuild/1` apaga projeções e reexecuta o log inteiro.

## O que cada tipo escreve

| Tipo | Efeito principal |
|---|---|
| `session.created` | Sem projeção de domínio (sessão identificada no log) |
| `workspace.attached` | Upsert `SESSION_WORKSPACES` attached=1 com roots/teams |
| `workspace.detached` | `SESSION_WORKSPACES` attached=0 |
| `task.requested` | Novo WI com `workspace_id`; ativa Run depth 0 |
| `task.resumed` | Novo Run `reason=retry` se WI failed |
| `task.delegated` | Filho WI + dependência; ativa Run filho |
| `task.completed` | WI `completed` + result; linha `COMMENTS` kind=result; pode continuar pai |
| `task.commented` | Linha `COMMENTS` com kind/body do payload |
| `task.resume_rejected` | Sem novo Run |
| `tool.call.requested` | (interceptável; sem projeção de domínio) |
| `tool.call.completed` | Atualiza checkpoint no Run |
| `run.started` | Linha `ARCHIVE_RUNS`; fixa tools e team no payload |
| `run.completed` | Fecha run; `outcome` inclui `waiting` + awaiting |
| `run.failed` | WI elegível a resume |
| `model.call.completed` | Linha `ARCHIVE_MODEL_CALLS` |
| `policy.loaded` | Hash da policy ativa (snapshot opcional) |
| `policy.changed` | Sem projeção de domínio; Runtime reage concedendo pedidos abertos |
| `permission.requested` | Linha `COMMENTS` kind=request |
| `permission.granted` | Linha `COMMENTS` kind=response |
| `permission.denied` | Linha `COMMENTS` kind=response |
| `permission.revoked` | Sem linha `COMMENTS`; revoga grant temporário no log |
| `inbox.read` | `COMMENTS.read_at` na linha alvo |
| `delivery.rejected` | Registro de bloqueio; envelope original permanece |

## Estado transitório (`monkey-job`)

`Agent.run/1` mantém em memória `messages`, dependências (`chat`, `context`,
`tools`, `schemas`), `turn`/`max_turns`, `usage`, `reporter`. Nada é reaberto
entre invocações.

`Config` normaliza TOML para `defaults`, `chat`, `output`, `presets`, mais
`agents`, `teams`, `workspaces`, `policy`, `session`, `interceptors`,
`automations`.

## Runtime in-memory

O processo `Omunculus.Runtime` guarda `runs`, `pids`, `handled` (dedupe de
entrega), `pending_continuations` (mapa work_item_id → continuações do pai),
`nodes` (cache de `node_id` por sessão/workspace/team).

`pending_continuations` é **reconstruído no boot** do Runtime
(`rebuild_pending_continuations/1` lê `WORK_ITEMS` em `waiting`, confere
`run.completed` waiting e `task.completed` dos filhos; `flush_pending_continuations/1`
retoma pais pendentes). Não é fonte de verdade — o log e as projeções são.

Cada `Run` é um GenServer temporário com checkpoint
(`messages`, `tool_state`, `pending`, `notes`, `awaiting`).

A separação planejada de conceitos ainda não implementados está em
[execution-model.md](../to-be/execution-model.md) e documentos TO-BE correlatos.

## Fechamento da fase 6 (2026-09-07)

`request_work` cria dependências pelo ancestral comum e reabre o solicitante;
`mediated` repassa, reescreve ou nega, preservando o checkpoint do ancestral.
`directory` e `TeamGate` compartilham escopo por sessão, workspace e time.
Tools negociáveis exigem concessão; revogação é consultada antes da execução.
`WORK_ITEMS.requested_by` é reconstruível do log e migra no schema 4.
A matriz cobre vinte combinações com filesystem isolado; 277 testes passam.
