# Etapa 0 — Núcleo

Fecha as sete tabelas e o store (funções + actions com regra). Sem ciclo de run.

**Aceite:** replay lê `EVENTS.sequence`. CRUD livre recusa. Sem archive, `PROJECTS`, checkpoint, claim.

## Plano

1. SQLite do projeto = as sete tabelas da §4. Só isso.
2. Store é API, não SQL exposto. Função = leitura para `view`. Action = escrita via `emit`.
3. `EVENTS` só append. `sequence` o harness preenche. Sem PATCH, sem DELETE.
4. Actions desta etapa existem no despacho; as que ainda não têm ciclo (abrir run) recusam com erro de etapa — não com SQL solto.
5. Implementar de verdade: append de event, `comment` (alvo existente), recusas. O resto do catálogo de actions entra nas etapas seguintes, no mesmo despacho.

## Implementação

### Núcleo

- Schema com as colunas da §4: `PROMPTS`, `EVENTS`, `RUNS`, `COMMENTS`, `WORKS`, `REQUESTS`, `INBOX`.
- IDs texto. FKs como no ERD. `REQUESTS.ask` e `WORKS.grants` / `RUNS.tools` como JSON texto.
- Módulo store: `view(name, ids)` e `apply(emit_list, ctx)`.
- `apply` é transação: o lote inteiro ou nada.
- Preencher `EVENTS.sequence` (max+1 no projeto), `at`, `id`.
- Replay: `SELECT * FROM EVENTS WHERE … ORDER BY sequence` — sem executar, sem tabela extra.

Funções (podem devolver vazio):

| Função | Recorte |
| --- | --- |
| `comments.work` | `COMMENTS` daquele `work_id` |
| `comments.request` | daquele `request_id` |
| `comments.inbox` | daquele `inbox_id` |
| `events.run` | `EVENTS` daquele `run_id` |
| `work` | aquele `WORKS` |

Actions no despacho (implementar regra; efeito completo só quando a etapa dona chegar):

| Action | Nesta etapa |
| --- | --- |
| `comment` | sim — alvo existente, `kind = note` |
| demais da §8.3 | recusam “ainda não” ou só validam schema |

### Pasta

Nenhuma.

### Testes

- Criar as sete tabelas; inserir fora do store falha ou não é o caminho.
- `comment` sem alvo recusa. Alvo inexistente recusa.
- Dois appends: `sequence` 1 depois 2. `UPDATE`/`DELETE` em `EVENTS` recusa.
- `REQUESTS.ask` não atualiza depois do create (quando create existir; senão teste de regra no store).
- Replay de N events na ordem de `sequence`, não de `at`.

## Não fazer

- `WORK_ITEMS`, `ARCHIVE_*`, `PROJECTS`, `PROJECTION_CURSORS`, `SESSION_WORKSPACES`, tabela `TOOLS`.
- Processo, sandbox, CLI, ceiling, hooks.
- Portar Event Core / projector / claim.

## Pronto quando

O projeto abre um SQLite, grava um comment via store, o replay lista o event, e o SQL direto não é a API.
