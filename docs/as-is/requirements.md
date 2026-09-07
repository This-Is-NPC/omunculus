Status: AS-IS — implementado

# Requisitos atuais

Requisitos abaixo são observáveis na CLI, na especificação KDL e nos testes da
branch `spike/event-core` (178 testes). Não são requisitos do alvo em `main`.
Consulte [architecture.md](architecture.md) e [data-model.md](data-model.md).

## Interface CLI

O binário `omunculus` oferece:

- `run <dir> <instruction...>`: loop Agent em memória no diretório;
- `monkey-job <instruction...>`: mesmo loop com tools/delay/counter explícitos;
- `spike <instruction...>`: Event Core end-to-end (`conte até N`);
- `events catalog` e `events follow [--db] [--types] [--after] [--once]`;
- `emit <type>`: append de comandos injetáveis ao log;
- `config check [--config]`: valida TOML expandido, interceptors e automations;
- `benchmark`: cenários `actor-density`, `agent-tree`, `http-load`;
- `help` e `version`.

Flags globais: `-h/--help`, `-V/--version`, `--verbose`. Códigos de saída: 0
(sucesso), 1 (erro host/chat/runtime), 2 (uso).

`spike` aceita `--depth`, `--fail-at`, `--delay`, `--db`, `--provider fake|chat`,
`--config`, `--profile`, `--model`, `--base-url`, `--api-key`, `--json-events`.

## Execução `run` (legado)

1. Canonicalizar diretório e impedir escape da raiz sandbox.
2. Resolver config na precedência flags > ambiente > TOML > defaults.
3. Enviar instrução ao chat com schemas das tools permitidas.
4. Repetir até resposta final ou `max_turns`.
5. Resposta em `stdout`; reporter em `stderr` quando aplicável.

Sem shell, sem commit Git, chat OpenAI-compatible sem streaming; `fake` para
testes determinísticos.

## Execução `spike` (Event Core)

1. Abrir SQLite temporário ou `--db`; iniciar Event Core, Projector, Runtime,
   Automations configuradas.
2. Append `task.requested` com a instrução; validar catálogo e deduplicar.
3. Interceptors avaliam entrega; rejeição produz `delivery.rejected` sem apagar
   o envelope.
4. Runtime ativa Run; rounds gravam `tool.call.*`, `model.call.completed`,
   `run.started` com tools efetivas da policy.
5. Concierge delega → `task.delegated` + `run.completed` waiting; worker conta
   com `counter` até N.
6. `task.completed` do filho reabre Run do pai (`reason=continuation`) com
   observação incluindo result e itens ainda em awaiting.
7. Texto com awaiting não vazio vai para `notes` no checkpoint, não gera
   `task.completed` prematuro.
8. `--fail-at n` mata o worker; `task.resumed` inicia nova tentativa.
9. Ao final: log ordenado, projeções, verificação de replay idêntico.

Policy inválida → `run.failed` `reason=policy_invalid`. `ToolGate` bloqueia tool
fora do granted fixado em `run.started`.

## Configuração e diagnóstico

TOML em camadas `~/.omunculus/config.toml` + projeto; `--config` substitui o
arquivo do projeto. Presets `coding` e `plan`; `${VAR}` exato; seções
`[agents]`, `[teams]`, `[workspaces]`, `[policy.depth]`, `[session]`,
`[[interceptors]]`, `[[automations]]`.

`config check` imprime bandas de policy expandidas e falha em módulo de
interceptor inexistente.

`events catalog` renderiza o catálogo de `Omunculus.Events`. `emit` aceita
somente tipos `injectable` (`task.requested`, `task.resumed`).

## Evidência e limites

Testes cobrem parser, config, Agent, chat, sandbox, tools, Event Core,
projeções, replay, interceptors, automations, policy em runtime, spike cenários
simple/medium/complex, `--fail-at`/resume e cenários 3/4 (dois Runs por WI
concierge).

Não há requisito implementado para: sessão/workspace como
agregados, permissões com efeito e inbox, `request_work`, `WorkspaceGate`,
runtime residente reagindo a `emit` em tempo real, nem substituição do `run`
legado por sessão durável. Esses itens estão no
[alvo TO-BE](../to-be/requirements.md) e não devem ser inferidos como
disponíveis hoje.
