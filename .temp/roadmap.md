# Roadmap

Como chegar no [spec.md](spec.md). Alto nível. O spec manda; isto só ordena o trabalho.

Plano e implementação por etapa: [steps/](steps/).

CLI-only. Sem tipo novo. Sem MCP, compact, `reviewer` nem preset até a fatia deles.

## Ordem

```text
núcleo → ciclo D0 → store + work → ceiling + request
      → sequência + filho → inbox + hook → catálogo + disco + bateria
      → v1.1 → MCP / preset
```

Cada etapa fecha um pedaço do ciclo (`descobrir → autorizar → chamar → EVENTS → action → próxima run`). Não se implementa “o harness antigo corrigido”.

## Etapas

| # | Etapa | Fecha | Aceite |
| --- | --- | --- | --- |
| 0 | **Núcleo** | Sete tabelas. Store: funções e actions com regra. `EVENTS` só append. Sem archive, `PROJECTS`, checkpoint, claim. | Replay lê `sequence`. CRUD livre recusa. |
| 1 | **Contrato e despacho** | Pasta `tool.toml` / `hook.toml`. `in` / `out`. Binário despacha `name`. `send` (`triggers = cli`) → action `prompt`. `assembled` na abertura. Sandbox `tools.*`. Modelo fake. | `D0-H0-W0` sem work: message → run → `end-run`. Trocar a pasta `send` não abre o núcleo. |
| 2 | **Work** | Tools `comment`, `work`. Próxima run lê work + último comment — não o log, não o `assembled` velho. Title ≠ message. | Concierge cria work. Segunda run junta de novo. |
| 3 | **Ceiling e request** | Remount a cada run. Camadas ∩ modos ∩ listas. `RUNS.tools` = snapshot. `request_access` + `reply`. Classificar have / askable / sealed / blocked no store. Grant no work. Permanente = escreve o TOML. | Pedido askable abre `REQUESTS`. Blocked não abre. `reply` grant remonta no **mesmo** stage. Depth 0 → pessoa. |
| 4 | **Sequência e filho** | Tools `continue`, `break`, `delegate`. Workflow no TOML. Tool não nomeia stage / agent / model. Pai `waiting = child`. | `D0-H0-W1`. Filho: `D1-H0-W0` / `D1-H0-W1`. Workflow off recusa `continue`. |
| 5 | **Inbox e hook** | Tools `notify`, `inbox`, `inbox_read`. Hooks da §9.6 (podem ser no-op). Hook reage; não abre run. | `D0-H1-W0`. Notify não trava. Inbox ≠ request. |
| 6 | **v1** | Disco (`fs.*`). `tool_search`. `counter` / `counter_decrement`. Agents `concierge` + `worker`. | Matriz D0 e D1 (os quatro × hook/workflow). Bateria `conte até 5`. |
| 7 | **v1.1** | `compact_comments` (composite). `reviewer`. `directory`. `workspaces`. | Compact some da linha do work; `EVENTS` fica. Reviewer só com workflow. |
| 8 | **Depois** | MCP (§8.7): lista de servidores → names. Preset `codex-like` / `pi-like` (`bash`, TOML). Permissão custom = outra tool que pede. | Sem tool `mcp` genérica. Ligar servidor não amplia ceiling. |

## Fora de ordem

Não entra no meio das etapas 0–6:

- MCP, resource/prompt do servidor
- Preset / `bash`
- `compact_comments`, `reviewer`, `directory`, `workspaces`
- Depth 2 (matriz D2) — só depois de D1 fechar
- Tabela `TOOLS`, pin de run velha, processo que espera

## Núcleo vs pasta

O núcleo (todas as etapas): contrato, store, sequência do TOML, remount, `assembled`, despacho do `name`.

A pasta (a partir da 1, cresce): `send`, `inbox`, `read`, `continue`, `request_access`, hooks, adaptador MCP.

## Matriz

A §6 do spec é o aceite de comportamento, não um eixo de implementação.

1. Etapas 0–2 → `D0-H0-W0`
2. Etapa 3 → o mesmo, com pedido
3. Etapa 4 → `D0-H0-W1`, depois D1
4. Etapa 5 → coluna Hook on
5. Etapa 6 → o restante de D0 e D1
6. D2 quando houver agent de depth 2 no TOML
