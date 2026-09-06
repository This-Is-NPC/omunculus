Status: TO-BE — planejado; catálogo, interceptores, automações e portas validados em spike. Tipos propostos ao fim ainda não estão no módulo

# Catálogo de eventos, interceptores e automações

Este documento fecha três lacunas do contrato: **quais** envelopes existem,
**quem** pode entrar na entrega de um envelope antes do consumidor, e **como**
um sistema externo observa e age sobre o harness. O envelope e as regras de
append continuam em [event-model.md](event-model.md); as entidades de runtime
em [execution-model.md](execution-model.md).

## Regra de fronteira

De fora só entram **comandos**; para fora só saem **eventos**. Um sistema
externo nunca escreve um evento: ele lê o log e responde com um comando pela
CLI. Eventos são sempre derivados pelo harness. Essa regra é o que mantém o
histórico interpretável e a administração pequena: existe um catálogo em
código e duas seções de configuração, `[[interceptors]]` e `[[automations]]`.
Nenhum terceiro mecanismo.

## Catálogo

O catálogo é um módulo (`Omunculus.Events`) onde cada tipo é declarado uma
única vez. O Event Core rejeita append de tipo desconhecido, de `kind`
divergente do catálogo, de `schema_version` não registrada ou de payload sem
os campos obrigatórios. A tabela abaixo é gerada do módulo por
`omunculus events catalog`; o módulo é a fonte, o documento é projeção.

Cada tipo declara:

- `kind`: `command` ou `event`;
- `schema_version` corrente e versões ainda aceitas;
- campos obrigatórios do payload;
- `emitted_by`: CLI, Run, Runtime ou Core;
- `interceptable`: se um interceptor configurado pode entrar na entrega;
- `injectable`: se pode ser emitido de fora pela CLI (`omunculus emit`).
  Só comandos podem ser injetáveis.

Os nomes seguem `<agregado>.<verbo>`. Comandos mantêm a forma já usada nos
cenários de [event-model.md](event-model.md) (`task.requested`,
`task.resumed`) para não reescrever o contrato existente; um comando é
reconhecido pelo `kind`, não pelo tempo verbal.

| Tipo | Kind | Payload obrigatório | Emitido por | Interceptável | Injetável |
|---|---|---|---|---|---|
| `task.requested` | command | `instruction` | CLI | sim | sim |
| `task.resumed` | command | — | CLI | sim | sim |
| `task.delegated` | event | `instruction`, `child_work_item_id`, `to_depth`, `parent_run_id`, `originating_run_id` | Run | sim | não |
| `task.completed` | event | `result`, `depth` | Run | sim | não |
| `task.resume_rejected` | event | `reason` | Runtime | não | não |
| `tool.call.requested` | event | `tool`, `round` | Run | sim | não |
| `tool.call.completed` | event | `tool`, `round`, `outcome` | Run | não | não |
| `run.started` | event | `attempt`, `depth`, `agent_id`, `agent_kind`, `reason` (`initial`, `continuation`, `retry`, `arbitration`) | Run | não | não |
| `run.completed` | event | `outcome` (`completed` ou `waiting`), `awaiting` e `checkpoint` quando `waiting` | Run | não | não |
| `run.failed` | event | `reason` | Run, Runtime | não | não |
| `model.call.completed` | event | `round`, `outcome` | Run | não | não |
| `delivery.rejected` | event | `rejected_event_id`, `rejected_type`, `interceptor`, `reason` | Core | não | não |

Evoluir um payload é registrar uma `schema_version` nova no catálogo e manter
a antiga aceita até que nenhum consumidor a declare. Nunca se edita uma versão
publicada.

### Tipos propostos, ainda fora do módulo

Vêm de [session-model.md](session-model.md),
[tool-policy.md](tool-policy.md) e
[permission-negotiation.md](permission-negotiation.md). Entram no módulo
quando a proposta correspondente for aceita.

| Tipo | Kind | Emitido por | Interceptável | Injetável | Origem |
|---|---|---|---|---|---|
| `session.created` | command | CLI | não | sim | session-model |
| `workspace.attached` | command | CLI | sim | sim | session-model |
| `workspace.detached` | command | CLI | sim | sim | session-model |
| `permission.requested` | event | Run | sim | não | permission-negotiation |
| `permission.granted` | command | Run (pai) ou CLI (humano) | sim | sim | permission-negotiation |
| `permission.denied` | command | Run, CLI ou Runtime | não | sim | permission-negotiation |
| `permission.revoked` | command | Run (pai) ou CLI | sim | sim | permission-negotiation |
| `policy.changed` | event | CLI | não | não | permission-negotiation |
| `policy.loaded` | event | Runtime | não | não | tool-policy |
| `task.commented` | command | CLI (humano) ou Runtime | sim | sim | session-model |
| `inbox.read` | command | CLI | não | sim | session-model |

`permission.granted` carrega `kind` (`temporary` ou `permanent`) e
`granter` (`run:<id>`, `human:<origin>` ou `policy`, quando o Runtime fecha
um pedido aberto que uma mudança de política satisfaz). `run.completed` com
`outcome = waiting` carrega `awaiting`: um `request_id`, um
`work_item_id` de filho ou dependência, ou `policy` quando a Run fecha só
para renascer com a política atual.

Campos de payload que as propostas acrescentam a tipos existentes:
`task.requested` ganha `profile`, `agent`, `workspace`, `team`, `origin` e
`requested_by`; `task.delegated` ganha `workspace`, `team`, `agent` e
`tools`; `run.started` ganha `profile`, `team`, `tools` e `roots`.

## Interceptor

Interceptor é a raia entre o Event Core e o consumidor desenhada nos cenários
1 e 2 de [event-model.md](event-model.md). Ele **não é global**: entra na
entrega somente dos tipos que declara, e só se estiver configurado. Sem
interceptor configurado para um tipo, a entrega é direta (cenários 3 e 4). O
log é idêntico nos dois caminhos.

```toml
[[interceptors]]
name = "depth-gate"
events = ["task.delegated"]
module = "Omunculus.Interceptors.DepthGate"
options = { max_depth = 2 }

[[interceptors]]
name = "audit"
events = ["task.requested", "task.completed"]
module = "Omunculus.Interceptors.Audit"
```

Contrato (`Omunculus.Interceptor`):

```elixir
@callback intercept(Envelope.t(), options :: map()) :: :deliver | {:reject, term()}
```

- roda dentro do harness, de forma síncrona, **após o commit** e **antes** da
  entrega ao consumidor, na ordem em que aparece na configuração;
- `:deliver` repassa o envelope intacto;
- `{:reject, reason}` bloqueia a entrega. O Core apenda `delivery.rejected`
  com `causation_id` no envelope barrado, para que a decisão fique no
  histórico; o envelope barrado continua no log, apenas não é entregue;
- nunca reescreve o envelope nem apenda por conta própria. Se um interceptor
  precisa produzir efeito, ele rejeita ou deixa passar; efeito é papel de
  consumidor.

Só tipos marcados `interceptable` no catálogo aceitam interceptor. Referenciar
outro tipo, ou um tipo inexistente, é erro de configuração na inicialização.

Um interceptor pode ser restrito por workspace com `workspaces = [...]`: ele
só entra em envelopes cujo `workspace_id` esteja na lista. Há um único Event
Core por sessão, então sem essa chave ele vê todos os workspaces. Os
interceptores do catálogo são `DepthGate`, `WorkspaceGate`, `ToolGate`,
`TeamGate` e `Audit`; `DepthGate` e `Audit` existem na spike, os outros são
propostas.

## Automação

Automação é um consumidor **externo**, assíncrono, que roda **depois** da
entrega. Não pode vetar. Só reage, e a única forma de agir de volta é emitir
um comando pela CLI.

```toml
[[automations]]
name = "notify"
events = ["task.completed", "run.failed"]
run = "./hooks/notify.sh"
```

- cada automação tem cursor próprio por `sequence` (persistido em
  `PROJECTION_CURSORS` como `automation:<name>`), então sobrevive a restart e
  retoma de onde parou;
- entrega é at-least-once: o script recebe o envelope em JSON na variável
  `OMUNCULUS_ENVELOPE` (mais `OMUNCULUS_EVENT_TYPE`, `OMUNCULUS_EVENT_ID`,
  `OMUNCULUS_DB`) e deve ser idempotente por `event_id`;
- se o script responder com um comando, deve derivar a `idempotency_key` do
  `event_id` que o originou. Retry não duplica efeito;
- saída diferente de zero não bloqueia o cursor: o harness registra a falha
  em log de processo e segue. Bloquear seria dar poder de veto a algo externo;
- `may_request = { profiles = [...], workspaces = [...] }` limita o que a
  automação pode pedir em `emit task.requested`, e o comando carrega
  `origin = "automation:<name>"` ([tool-policy.md](tool-policy.md)).

## Portas da CLI

Coerente com a decisão CLI-only de [architecture.md](architecture.md), há
duas portas e nenhuma outra:

- **saída** — `omunculus events follow --db <arquivo> [--types a,b] [--after <seq>] [--once]`:
  leitura ordenada de `EVENTS` em NDJSON, um envelope por linha, com cursor.
  É o viewport de [recommendations.md](recommendations.md); qualquer GUI ou
  automação lê daqui;
- **entrada** — `omunculus emit <tipo> --db <arquivo> --payload '<json>' [--idempotency-key k] [--correlation-id c]`:
  só tipos `command` marcados `injectable`. O Core valida contra o catálogo e
  atribui identidade e `sequence`;
- **catálogo** — `omunculus events catalog`: lista os tipos e suas
  propriedades a partir do módulo;
- **verificação** — `omunculus config check [--config <arquivo>]`: valida
  `[[interceptors]]` e `[[automations]]` contra o catálogo e a existência dos
  módulos.

## Não-objetivos

Não introduzir um segundo barramento, um registro de tipos em arquivo
separado do código, interceptor que reescreva envelope, automação com poder de
veto, ou ingestão de eventos vindos de fora. Um runtime residente que reaja a
`emit` em tempo real fica para depois desta validação.
