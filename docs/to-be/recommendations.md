Status: TO-BE — planejado, não implementado

# Recomendações de terreno

Este documento reserva encaixes no contrato para capacidades já conhecidas
(orquestra multi-workspace, concierges, attach/detach, BYO-UI) sem tratá-las
como backlog de implementação. Não substitui as decisões canônicas de
[architecture.md](architecture.md). Onde o modelo atual colapsa identidades,
aponta o encaixe que deve existir no envelope, nas entidades e na CLI — para
depois só nascer evento, node e comando, sem mudança estrutural.

As regras de `EVENTS` continuam em [event-model.md](event-model.md). As
entidades de runtime continuam em [execution-model.md](execution-model.md).
As tabelas mínimas continuam em [data-model.md](data-model.md).

## Propósito

O harness de baixo já aguenta orquestra. O que falta não é outra árvore de
agentes: é amarrar sandbox ao node, tratar sessão como agregado durável e
deixar qualquer UI ser só consumidora do Event Core. Sem esses encaixes,
multi-workspace, attach e frontend viram refactor.

Isto não é priorização de feature. É o conjunto de identidades e substantivos
que o contrato precisa carregar mesmo antes dessas superfícies existirem.

## O que já está certo

- A configuração **Agent** não declara `reports_to`, `parent` ou `depth`.
  `kind` é capability, não posição. A mesma config pode ocupar depths
  diferentes em execuções diferentes.
- **Execution Node** já é o lugar de parent, depth e reporting. Delegação
  cria node/Run em runtime; a árvore é projeção, não arquivo de Agent.
- O **Event Core** já é o barramento entre camadas: append em `EVENTS` antes
  de dispatch, `sequence`, `schema_version`, correlação, causação, replay.
- A superfície pública de ingresso é **CLI-only**. Não há HTTP, MCP ou TUI
  como API do harness.
- Processo OTP residente não é entidade de negócio.

Essas decisões não devem ser revertidas para acomodar orquestra ou UI.

## Quatro identidades que o contrato ainda mistura

### 1. Session durável ≠ processo OTP

Em [execution-model.md](execution-model.md), Session ainda nomeia o processo
OTP efêmero que atende uma Run. A sessão que anexa workspaces é outra coisa:
o agregado que o humano nomeia, que sobrevive ao TTY e que administra
trabalho em vários workspaces.

O envelope precisa de `session_id` distinto de `correlation_id`.

- `correlation_id` = uma operação lógica (um attach, um send, um follow).
- `session_id` = a orquestra inteira.

Sem essa distinção, membership, follow e GUI não têm onde pendurar. O
processo some; a sessão e os eventos ficam. Retry, crash e detach não
recriam a sessão — recriam runtime que a atende.

### 2. Workspace no Execution Node, não no Agent e não no cwd

Workspace é identidade estável (`workspace_id`, slug) mais sandbox
(`roots[]`). Pertence ao Execution Node (e à membership na sessão), não à
configuração Agent e não ao diretório atual da CLI.

`PROJECTS` continua sendo o projeto da casa. Não é a sessão. Não é o node.
Não é o cwd de `run <dir>`. Um Work Item pode referenciar `project_id`
opcionalmente; a orquestra não exige que todo trabalho caiba num único
projeto.

Anexar um workspace é membership na sessão (`workspace.attached` /
`workspace.detached`), não spawnar um filho e chamar isso de attach. Depth 1
vive dentro de um workspace; depth 0 não.

O modelo não recebe permissão para escapar do sandbox apenas por delegar.

### 3. Concierge é posição, não tipo de Agent

Depth é imutável no node.

- Depth 0: concierge de concierges — administra a sessão / orquestra.
- Depth 1: concierge de um workspace — repo, projeto ou conjunto de repos.
- Depth 2: worker.

Não há hierarquia estática de Agents. Não se promove worker a concierge.
Não se mata um processo OTP para “detach”. Attach/detach de concierge é
entrar ou sair da sessão: o node e o histórico permanecem; o runtime pode
ir embora.

A orquestra descrita (vários workspaces sob uma sessão central) **já é**
essa árvore. Não precisa de uma quarta camada.

### 4. Event Core é o único barramento

Orquestra não ganha um segundo canal. Depth 0 não compartilha contexto com
depth 1: manda trabalho por comando → `EVENTS` → Work Item e eventos de
delegação/conclusão. Tool, round, membership, falha e attach usam o mesmo
envelope.

`--json-events` no AS-IS é um Reporter de processo (NDJSON no stderr da
Run). Não é o contrato de observação. O follow da GUI e da CLI no alvo é
leitura ordenada de `EVENTS` (`sequence`, `schema_version`), filtrada por
`session_id` / viewport — não um dump paralelo do TTY e não um snapshot
que substitua o log.

Campos a reservar no envelope, além do mínimo já em
[event-model.md](event-model.md): `session_id`; `workspace_id` quando o
evento for scoped a um workspace. `project_id`, `work_item_id` e `run_id`
permanecem opcionais como hoje.

## Ingress e observação

O padrão público é estável e único:

- **comando entra** pela CLI (o mesmo vocabulário que um humano digita);
- **evento sai** pelo stream do Event Core.

A GUI não é API do harness. Não carrega QML no Core. Não fala HTTP, socket
próprio, MCP ou plugin de desktop como contrato. O host (Omarchy/Quickshell
ou outro) só instancia o cliente; o usuário pode escrever o QML que quiser.

O que a UI precisa no futuro (workspace, sessão, attach/detach, concierge)
entra como **novos verbos na CLI** e **novos tipos no stream**, com
`schema_version`. Enquanto a GUI ler eventos de run/sessão — e não o layout
do TTY, nem campos ad-hoc de um Reporter — o frontend permanece desacoplado.

Spawnar o binário não é o modelo de sessão. Uma janela que morre não encerra
a orquestra.

## CLI: substantivos das entidades

A CLI legível nomeia as identidades acima, em vez de tratar `run <dir>`
como se o diretório fosse a sessão.

Verbos do terreno (forma ilustrativa, não sintaxe normativa):

- `session` — criar, retomar, nomear a orquestra;
- `workspace attach|detach` — membership, não viewport;
- `send` — trabalho para a sessão / um workspace;
- `events follow` — observação ordenada do log, não scrape de TTY.

Follow é viewport (o que o cliente assiste). Attach é membership (o que
pertence à sessão). Os dois não se confundem: pode-se seguir uma sessão
sem anexar um workspace, e anexar sem estar olhando o stream.

Validação de argumentos e configuração permanece na CLI; o Core só vê
envelope de comando, igual ao fluxo de [architecture.md](architecture.md).

## Não-objetivos

Não introduzir HTTP/MCP/TUI públicos, um bus paralelo ao Event Core, uma
tabela de eventos por domínio, hierarquia estática de Agents, Session como
sinônimo de processo OTP, sandbox na config Agent, ou uma GUI embutida no
harness. Este arquivo não prioriza ordem de implementação.
