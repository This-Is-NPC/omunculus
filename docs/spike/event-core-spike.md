Status: SPIKE — código descartável na branch `spike/event-core`

# Spike do Event Core

Fatia vertical que exercita todo o [TO-BE](../to-be/architecture.md) com a
tarefa `conte até N` dos cenários 3 e 4 do
[event-model.md](../to-be/event-model.md), sem provider real. O objetivo é
validar o contrato, não entregar produto: os módulos podem ser reescritos.

```sh
mix escript.build
./omunculus spike "conte até 10" --depth 2            # cenário 4
./omunculus spike "conte até 10" --fail-at 3 --delay 30ms   # crash + retomada
./omunculus spike "conte até 10" --db ./spike.sqlite3 --json-events
```

`stdout` recebe só o resultado durável. `stderr` recebe a leitura ordenada
de `EVENTS` (sequence, kind, type, event_id ← causation_id), as projeções
`ARCHIVE_RUNS`/`WORK_ITEMS` e o resultado do replay.

## O que foi implementado e onde

| Contrato TO-BE | Módulo | Teste |
|---|---|---|
| Envelope (`event_id`, `kind`, `type`, `schema_version`, `sequence`, correlação, causação, `idempotency_key`, `session_id`/`workspace_id` reservados) | `Omunculus.Event.Envelope` | `event_core_test.exs` |
| SQLite/WAL com as seis tabelas + `EVENTS` | `Omunculus.EventCore.Store` | — |
| Event Core: validar → dedupe → append+commit → só então notificar | `Omunculus.EventCore` | `event_core_test.exs` |
| Reducers idempotentes com cursor e precondição por linha; rebuild por replay | `Omunculus.EventCore.Projector` | `event_core_test.exs`, `runtime_test.exs` |
| Execution Node/Run criados por evento entregue; árvore derivada de `parent_run_id`/`originating_run_id`/depth | `Omunculus.Runtime` | `runtime_test.exs` |
| Run como processo efêmero; tool call e delegação fazem round-trip pelo Core antes de continuar | `Omunculus.Runtime.Run` | `runtime_test.exs` |
| Agent como configuração genérica sem `parent`/`depth`; mesma config em depths diferentes | `Omunculus.Runtime.SpikeAgents` | `runtime_test.exs` |
| Retry cria nova Run a partir do checkpoint; Run anterior nunca reaberta | `Runtime.resume/3` + `derive_resume/2` | `runtime_test.exs`, `spike_test.exs` |
| CLI-only: comando entra, projeção sai | `Omunculus.CLI.Spike` | `spike_test.exs` |

Os cenários 3 e 4 viraram fixtures: o teste afirma que a cadeia
`task.requested → task.delegated… → tool.call.requested[1] → tool.call.completed[1]
→ … → tool.call.completed[10] → task.completed(folha) → … → task.completed(raiz)`
é linear e que cada `causation_id` aponta para o envelope anterior, como na
tabela do documento.

## Decisões tomadas na spike

- **Eventos que o TO-BE não nomeava**: `run.started`, `run.completed`,
  `run.failed`, `model.call.completed`, `task.resumed` (comando) e
  `task.resume_rejected`. Sem eles `ARCHIVE_RUNS` e `ARCHIVE_MODEL_CALLS` não
  têm evento-fonte. Eles ficam **fora** da cadeia de causação dos cenários:
  `run.*` é causado pelo envelope de ativação e `model.call.*` pelo
  `run.started`, preservando a cadeia documentada.
- **Work Item por delegação**: `task.delegated` carrega
  `child_work_item_id` e cria o Work Item filho; o pai vira `waiting` e ganha
  uma linha em `WORK_ITEM_DEPENDENCIES` (pai depende do filho).
- **`PROJECTION_CURSORS`**: oitava tabela, justificada como checkpoint
  reconstruível (não é histórico nem cópia de `EVENTS`). Permite aplicar
  evento e avançar cursor na mesma transação.
- **Entrega**: o Core notifica assinantes após o commit; a Run só continua
  quando recebe de volta o envelope que ela mesma apendou. Isso reproduz
  literalmente as setas `append + commit → deliver` dos diagramas.
- **Checkpoint**: `tool.call.completed` carrega o estado da tool; a retomada
  deriva depth, parent, attempt e checkpoint **do log**, não da memória do
  runtime.
- **Interceptor** (cenários 1 e 2) ficou de fora por não estar definido em
  nenhum documento.
- **Sessão/workspace** de `recommendations.md`: apenas colunas reservadas no
  envelope, sempre nulas.

## O que a spike revelou no TO-BE

1. `event-model.md` precisa nomear os eventos de Run e de chamada de modelo,
   ou dizer explicitamente que são derivados de `tool.call.*`/`task.*`.
2. O envelope em `event-model.md` deve incluir `session_id` e
   `workspace_id` (hoje só em `recommendations.md`).
3. "Sucesso da CLI = commit" e "CLI aguarda resposta derivada" pedem uma
   semântica de espera: `Runtime.request/3` espera o `task.completed` da raiz
   e, se o comando for uma re-submissão idempotente, lê o resultado do log.
4. `Interceptor` deve virar Dispatcher/consumer nomeado ou sair dos cenários.
5. A ordem de dedupe importa: `event_id` igual com conteúdo igual é
   redelivery; `idempotency_key` igual com payload diferente é conflito
   explícito. Ambos testados.

## Matriz `conte até 10`: profundidade × Interceptor

Seis casos, cada um executado com o modelo scriptado (`--provider fake`) e
com o `qwen3.5:4b` (`--provider chat`). "Com lane" usa
`examples/spike-interceptors.toml`: `audit` em `task.requested`,
`task.delegated`, `tool.call.requested` e `task.completed`, e `depth-gate`
em `task.delegated` com `max_depth = 2`. Sem lane, a entrega vai direta do
Event Core (cenários 3 e 4). Com lane, passa pelos interceptores configurados
para aquele tipo (cenários 1 e 2).

```sh
./omunculus spike "conte até 10" --depth 2                                       # sem lane
./omunculus spike "conte até 10" --depth 2 --config examples/spike-interceptors.toml   # com lane
./omunculus spike "conte até 10" --depth 2 --provider chat --config examples/spike-local-interceptors.toml
```

| Depth | Lane | Cadeia (tipos, sem `run.*`/`model.call.*`) | Scriptado | qwen3.5:4b | `depth-gate` |
|---|---|---|---|---|---|
| 0 | sem | `task.requested → 10×(tool.call.requested → tool.call.completed) → task.completed(0)` | 35 env., `10` | 36 env., `10` | — |
| 0 | com | idêntica | 35 env., `10` | 35 env., `10` | evaluated=0 |
| 1 | sem | `task.requested → task.delegated(→1) → 10×(…) → task.completed(1) → task.completed(0)` | 41 env., `10` | 42 env., `10` | — |
| 1 | com | idêntica | 41 env., `10` | 1ª: timeout HTTP do provider na rodada 9, `run.failed` durável, checkpoint 8; 2ª: 43 env., `10` | evaluated=1 delivered=1 |
| 2 | sem | `task.requested → task.delegated(→1) → task.delegated(→2) → 10×(…) → task.completed(2) → task.completed(1) → task.completed(0)` | 47 env., `10` | 49 env., `10` | — |
| 2 | com | idêntica | 47 env., `10` | 58 env., worker passou de 10, chegou a 13 e estourou `max_turns`; resultado vazio subiu a árvore como `""` → `"1"` → `"2"` | evaluated=2 delivered=2 |

Leitura:

- **A lane não altera o log.** Nos seis casos scriptados a cadeia de
  causação é a mesma com e sem interceptor, e os contadores por interceptor
  provam que ele foi avaliado. É a garantia de "observar ou vetar, nunca
  reescrever".
- **Veto aparece no histórico.** Com `max_depth = 1` e `--depth 2`, o
  segundo `task.delegated` é barrado: `delivery.rejected` com causação nele,
  nenhuma Run de depth 2 nasce, e o `task.completed` do nó delegador tem
  causação na rejeição. Testado em `interceptors_test.exs`.
- **As falhas reais são do provider, não do contrato.** O timeout HTTP virou
  `run.failed` com checkpoint 8, exatamente o caso que `task.resumed` cobre.
  O worker que passou de 10 mostra que `max_turns` é o único freio quando o
  modelo ignora o alvo; o `counter_target` do `Agent` só empurra para cima,
  nunca para parar.
- **Resultado vazio propaga.** Um `result` vazio no worker virou `"1"` e
  `"2"` inventados pelos concierges. Reforça o achado anterior: `result`
  precisa de campo estruturado, e um concierge não deveria aceitar resultado
  vazio como conclusão.

## Provider real

`--provider chat` troca o `Chat.Fake` por um chat OpenAI-compatível
construído pelo mesmo caminho de `run`, a partir de `--config` e das flags
`--model`, `--base-url` e `--api-key`. Sem essa flag, `--config` só fornece
`[[interceptors]]` e `[[automations]]`. A configuração Agent continua genérica: só `kind`, tools e
`system_prompt` mudam por depth.

```sh
./omunculus spike "conte até 10" --depth 2 --provider chat --config presets/local.toml
```

Resultado com `qwen3.5:4b` servido pelo FastFlowLM em 2026-09-06:

| Execução | Cadeia | Resultado | Observação |
|---|---|---|---|
| depth 1, sem `system_prompt` próprio | quebrou | prosa em português | o concierge herdou o prompt de coding agent e emitiu um tool call sem nome |
| depth 1, com `system_prompt` e `nudge` | completa, 42 envelopes | `10` | duas execuções seguidas, ambas corretas |
| depth 2, com `system_prompt` e `nudge` | completa, 78 envelopes | `20` | o concierge raiz reescreveu a instrução para "count up to 20." e o worker obedeceu |

Achados que valem para o TO-BE:

1. **Deriva de instrução na delegação.** `task.delegated` hoje carrega a
   `instruction` que o modelo escreveu. O Work Item filho deveria referenciar
   o Work Item pai (instrução original, critérios) e tratar o texto do modelo
   como complemento, senão a árvore executa outra tarefa com a cadeia de
   causação perfeitamente íntegra.
2. **Prompt é parte da configuração Agent.** O base prompt fixo do `Agent`
   presume filesystem e coding; um nó concierge precisa do seu próprio.
   `system_prompt` e `nudge` viraram opções do `Agent` por isso.
3. **`task.completed.result` é texto livre.** O worker devolveu "We've
   reached the target of 10!..." numa execução e "10" noutra. Se o resultado
   for contrato entre nós, o payload precisa de um campo estruturado além do
   texto (por exemplo o checkpoint da tool).
4. **Latência do round-trip pelo log é desprezível** frente ao modelo: cada
   tool call custa dois appends e duas entregas, na casa de milissegundos,
   contra 2 a 4 segundos por chamada de modelo local.

## Fora da spike

Sandbox por node, budget além de profundidade máxima,
reducers de `COMMENTS` além do resultado, retenção/compactação, sessão e
workspace como agregados, GUI.

## Nota de ambiente

O escript não carrega NIFs de dentro do arquivo. `Omunculus.Native` embute o
`sqlite3_nif.so` no build e o extrai para `~/.cache/omunculus/` na inicialização.
