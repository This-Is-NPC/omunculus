# Etapa 2 — Work

Fecha a verdade do trabalho: work + último comment. `send` continua só message.

**Aceite:** concierge cria work. A segunda run junta de novo (title + último comment). Title ≠ message.

## Plano

1. Tools `work` e `comment`. Actions `work` e `comment` (comment já existe; work completa).
2. `send` não cria work. O modelo chama `work` e escreve o `title`.
3. Abrir run com work: assembled ganha title + último comment daquele `work_id`. Sem work, igual à etapa 1.
4. Quem continua lê work + último comment — não o log, não o `assembled` anterior.
5. Workflow ainda off: `WORKS.stage` vazio. `state = open`. Sem `continue`.

## Implementação

### Núcleo

- Action `work`: cria ou atualiza `WORKS` + `EVENTS(work)`. `parent_id` vazio = raiz. Sem workflow: não grava stage, não escolhe etapa.
- Ligar run ↔ work quando a run já existe e o modelo cria o work no meio — `RUNS.work_id` / events com `work_id`.
- Assemble: se há `work_id`, incluir `WORKS.title` e o último `COMMENTS` daquele work (`ORDER BY created_at` / event sequence).
- `comment` com `work_id`. Pelo menos um alvo.

### Pasta

```text
tools/work/tool.toml      triggers = ["model"]
tools/work/run            emit { type = "work", body = { title, … } }
tools/comment/tool.toml
tools/comment/run         emit { type = "comment", body = { work_id, body } }
```

Ceiling desta etapa: concierge tem `work` e `comment`. Ainda sem interseção de camadas.

### Testes

- `send "conte até 5"` não cria `WORKS`.
- Fake chama `work` com title próprio → linha em `WORKS`; title ≠ message.
- Fake chama `comment` no work → segunda run (abrir de novo no mesmo work, ainda sem `continue`: teste de assemble isolado ou `send` seguinte apontando o work se o CLI permitir id; senão teste de unidade do assemble).
- Assemble da segunda abertura: agent text + title + último comment. Sem o `assembled` da primeira. Sem o log no prompt.
- Comment sem alvo recusa (já na 0; manter).

## Não fazer

- `continue`, `break`, `delegate`, `request`, inbox.
- Copiar message para title no `send`.
- Sequência de workflow, primeiro stage automático (isso é etapa 4, na action `work` quando workflow on).

## Pronto quando

O fio é work + último comment. A message do `send` ficou em `PROMPTS`.
