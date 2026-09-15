# Etapa 3 — Ceiling e request

Fecha permissão: remount a cada run, pedido via `REQUESTS`, grant no work.

**Aceite:** askable abre `REQUESTS`. Blocked não abre. `reply` grant remonta no **mesmo** stage. Depth 0 → pessoa.

## Plano

1. Antes de cada run: ler o TOML **agora** e o work **agora**. Não reusar `RUNS.tools` da run anterior.
2. `ceiling = workspace ∩ depth ∩ stage ∩ agente`. `effective = (ceiling ∪ grants do work ∪ ancestrais) − deny`.
3. Modos `allowlist` / `blocklist` / `auto`. Listas `granted`, `negotiable`, `human`, `deny`. Precedência: deny > human > negotiable > granted.
4. Tool `request_access` emite `request`. Store classifica `ask.name`. Tool não decide ceiling.
5. Tool `reply` (triggers `cli` e `model`): grant | deny. Temporária → `WORKS.grants`. Permanente → escreve o TOML da camada.
6. Action `request` prepara a run do arbiter se for agente. Action `reply` grant prepara run no mesmo stage — não é `continue`.
7. A run que pediu termina. Nenhum processo espera. Work `waiting = access`.

## Implementação

### Núcleo

- Resolver camadas do TOML (`[policy]`, workspace, depth, agent, stage se existir — stage vazio se workflow off).
- Classificar cada `name` do catálogo: have / askable / sealed / blocked. Snapshot have → `RUNS.tools`. Askable/sealed no `body` do `start-run`.
- Cards no assembled = só have (+ `tool_search` quando existir). Blocked não lista.
- Action `request`:
  - have → não abre; output “já tem”
  - blocked → `EVENTS(deny)`; run termina; sem `REQUESTS`
  - askable + agente acima com autoridade (have ∪ askable dele) → `REQUESTS` `waiting_agent`
  - sealed, ou askable sem de cima, ou depth 0 → `waiting_human`, arbiter `human`
  - grava `ask`, comment (`reason`), `EVENTS(request)`; work → `waiting = access`; encerra a run; se arbiter agente, abre a run dele
- Action `reply`: comment + grant/deny + `EVENTS(reply)`. Grant + work → `WORKS.grants` += `ask.name`, `waiting` open, nova run **mesmo** stage. `REQUESTS.ask` imutável.
- Grant permanente: `reply` com modo permanente escreve o ficheiro na camada indicada; não grava `grants`.
- Ancestrais: na abertura, `grants(W) = W.grants ∪ grants(parent)`. Não irmão.
- Deny de qualquer camada corta grant.

`ask` default: `{ kind: tool|path|directory, name }`. Outro `kind` já classifica pelo `name` (premissa 12); não precisa de tool extra nesta etapa.

### Pasta

```text
tools/request_access/tool.toml    emit request { kind, name, reason }
tools/reply/tool.toml             triggers = ["cli", "model"]
```

Default: depth 0 `concierge` — pedido vai à pessoa. `reply` via CLI.

### Testes

- Remount: mudar o TOML entre duas runs; a segunda vê o ficheiro novo.
- Askable → `REQUESTS` + comment + run do pedinte `done`. Arbiter agente: run nova. Depth 0: `waiting_human`, sem run de arbiter.
- Blocked: sem `REQUESTS`, `EVENTS(deny)`, run `done`.
- Have: sem `REQUESTS`.
- `reply` grant temporário: `WORKS.grants` tem o name; próxima run no mesmo stage tem a tool no effective. Run velha não ganha.
- `reply` permanente: TOML mudou; outro work na mesma camada vê o acesso; `grants` desse work não precisa do name.
- Grant não fura `deny` da camada.
- Sem work ligado: request pode existir; grant temporário não grava em work nenhum.

## Não fazer

- `continue` / `delegate` / inbox / hook sequencer.
- Auto-grant sem `REQUESTS`.
- Tool `mcp` ou kind que amplie ceiling sozinho.
- Pin de tools da run anterior.

## Pronto quando

Pedir e responder é `REQUESTS` + `reply`. Ceiling nasce de ficheiro + grants do work, a cada abertura.
