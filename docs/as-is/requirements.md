Status: AS-IS — implementado

# Requisitos atuais

Requisitos abaixo são observáveis na CLI, na especificação KDL e nos testes da
branch `master` (277 testes). Não são requisitos do alvo TO-BE.
Consulte [architecture.md](architecture.md) e [data-model.md](data-model.md).

## Interface CLI

O binário `omunculus` oferece:

- `run <dir> <instruction...>`: Event Core efêmero (tmp sqlite, `session.created`
  + `workspace.attached`, `Runtime.request`, arquivo removido ao sair);
- `monkey-job <instruction...>`: loop Agent em memória com tools/delay/counter;
- `spike <instruction...>`: Event Core end-to-end (`conte até N`);
- `session create [name]` e `session list`: log durável com `session.created`;
- `workspace attach <name>` e `workspace detach <name>`: `workspace.attached` /
  `workspace.detached` no log da sessão;
- `send <instruction...>`: abre sessão durável, Runtime + Projector, espera
  `task.completed` (ou só append com `--detach`);
- `inbox`: lista pedidos de permissão abertos e resultados não lidos;
- `inbox reply <request_id> --grant|--deny`: responde a um pedido (opcional
  `--permanent` e `--config` para grant permanente via patch de TOML);
- `inbox read <id>`: marca comentário ou result como lido (`inbox.read`);
- `events catalog` e `events follow [--db] [--session] [--types] [--after] [--once]`;
- `emit <type>`: append de comandos injetáveis ao log (inclui
  `permission.granted`, `permission.denied`, `permission.revoked`, `inbox.read`;
  `--request-id` preenche campos de um `permission.requested` aberto);
- `config check [--config]`: valida TOML expandido, interceptors e automations;
- `benchmark`: cenários `actor-density`, `agent-tree`, `http-load`;
- `help` e `version`.

Flags globais: `-h/--help`, `-V/--version`, `--verbose`. Códigos de saída: 0
(sucesso), 1 (erro host/chat/runtime), 2 (uso).

SQLite de sessão: padrão `~/.omunculus/session.sqlite3`; `--db` ou `--session`
selecionam o arquivo (`--db` vence quando ambos presentes); `OMUNCULUS_SESSION`
via ambiente. Mesma resolução em `events follow`, `emit`, `session`, `workspace`,
`send` e `inbox`.

`spike` aceita `--depth`, `--fail-at`, `--delay`, `--db`, `--provider fake|chat`,
`--config`, `--profile`, `--model`, `--base-url`, `--api-key`, `--json-events`.

`send` aceita `--workspace`, `--profile`, `--config`, `--detach`, `--tools`.

## Execução `run` (Event Core efêmero)

1. Canonicalizar diretório e carregar config.
2. Criar SQLite temporário; append `session.created` e `workspace.attached` (roots
   do cwd; workspace inferido do TOML ou `default`).
3. Iniciar Event Core, Projector, Runtime; `task.requested` com `session_id` e
   workspace no payload.
4. Interceptors (incl. configurados) avaliam entrega; rejeição →
   `delivery.rejected`.
5. Esperar `task.completed`; imprimir `result`; remover o arquivo sqlite.

Provider opcional (`--provider chat` + credenciais); sem provider usa
`Runtime.Agents` com scripts fake explícitos. Não persiste log entre invocações.

## Execução `monkey-job` (legado)

1. Resolver config na precedência flags > ambiente > TOML > defaults.
2. Enviar instrução ao chat com schemas das tools permitidas (`Runner` → `Agent`).
3. Repetir até resposta final ou `max_turns`.

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
fora do granted pinado em `run.started` salvo grant temporário ativo na linhagem.
`WorkspaceGate` (quando injetado) bloqueia workspace não anexado.

## Sessão durável (`session` / `workspace` / `send` / `inbox`)

1. `session create` prepara diretório do db e grava `session.created` (nome
   opcional ou id gerado).
2. `workspace attach` lê roots/teams de `[workspaces]` no TOML e grava
   `workspace.attached`; `detach` grava `workspace.detached`.
3. `send` garante `session.created` se o log estiver vazio; resolve interceptors
   com workspaces anexados e adiciona `WorkspaceGate` quando aplicável.
4. `Runtime.request` com `--workspace` ou `--detach` (só append `task.requested`).
5. `pending_continuations` reconstruído no `init` do Runtime a partir do log.
6. `inbox` lê projeções e log sem iniciar Runtime; `inbox reply` apenda
   `permission.granted`/`permission.denied` (permanente opcional via patch de
   TOML + `policy.changed`) e entrega ao Runtime da sessão; `inbox read` apenda
   `inbox.read`.

## Configuração e diagnóstico

TOML em camadas `~/.omunculus/config.toml` + projeto; `--config` substitui o
arquivo do projeto. Presets `coding` e `plan`; `${VAR}` exato; seções
`[agents]`, `[teams]`, `[workspaces]`, `[policy.depth]`, `[session]`,
`[[interceptors]]`, `[[automations]]`.

`config check` imprime bandas de policy expandidas e falha em módulo de
interceptor inexistente.

`events catalog` renderiza o catálogo de `Omunculus.Events`. `emit` aceita
tipos `injectable` (`task.requested`, `task.resumed`, `session.created`,
`workspace.attached`, `workspace.detached`, `task.commented`,
`permission.granted`, `permission.denied`, `permission.revoked`, `inbox.read`,
…).

## Evidência e limites

Testes cobrem parser, config, Agent, chat, sandbox, tools, Event Core,
projeções, replay, interceptors (incl. `WorkspaceGate` e `ToolGate` com grants
temporários), automations, policy em runtime, spike cenários simple/medium/complex,
sessão/workspace/send, `--fail-at`/resume, cenários 3/4 (dois Runs por WI
concierge) e três blocos de permissões (temporária, permanente, arbitragem do
pai) mais `complex.toml` com e sem lane (faixa `human`).

Não há requisito implementado para runtime residente reagindo a `emit` em tempo real. Não
existe verbo CLI `policy grant` (permanente via `inbox reply --grant
--permanent`). Esses itens estão no [alvo TO-BE](../to-be/requirements.md) e
não devem ser inferidos como disponíveis hoje.

## Fechamento da fase 6 (2026-09-07)

`request_work` cria dependências pelo ancestral comum e reabre o solicitante;
`mediated` repassa, reescreve ou nega, preservando o checkpoint do ancestral.
`directory` e `TeamGate` compartilham escopo por sessão, workspace e time.
Tools negociáveis exigem concessão; revogação é consultada antes da execução.
`WORK_ITEMS.requested_by` é reconstruível do log e migra no schema 4.
A matriz cobre vinte combinações com filesystem isolado; 277 testes passam.
