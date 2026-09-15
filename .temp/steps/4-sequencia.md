# Etapa 4 — Sequência e filho

Fecha workflow e depth 1. A tool só pede “próximo”, “estaciona” ou “filho”.

**Aceite:** `D0-H0-W1`. Filho: `D1-H0-W0` / `D1-H0-W1`. Workflow off recusa `continue`.

## Plano

1. Sequência no TOML (`backlog` → … → `done`). Não na tool.
2. Action `work` com workflow on: primeiro stage, agent da linha, remount, (se a action pedir) run.
3. `continue` — próximo stage, remount, próxima run. Último stage → `state = done`, sem run nova. Tool sem stage/agent/model.
4. `break` — `waiting`, run acaba, sequência não anda. Volta ao mesmo stage quando `reply` grant ou filho `done`.
5. `delegate` — work filho, pai `waiting = child`, primeira run do filho (primeiro stage dele). `grants` não se copiam; a abertura do filho sobe `parent_id`.
6. Workflow off: `continue` / `break` recusam ou o ceiling não lista. `delegate` ainda cria filho se o ceiling tiver a tool.

## Implementação

### Núcleo

- Ler `steps` do workflow: `name`, `agent`, ceiling da etapa.
- Action `continue`: `EVENTS(continue)`; end-run; próximo name no array; remount; abrir run do agent da linha. Fora da sequência = recusa.
- Action `break`: `EVENTS(break)`; `WORKS.waiting` (access já existe; break sem request = waiting sem `access`/`child` ou o spec usa waiting + comment — gravar waiting e comment; não andar stage).
- Action `delegate`: cria filho (`parent_id`), comment, pai `waiting = child`, `waiting_for` / `waiting_from` se couber; prepara run do filho.
- Filho `done` (último `continue` do filho): pai volta `open`, mesmo stage; action que fecha o filho prepara run do pai se o protocolo pedir (filho done → pai continua no mesmo stage).
- `via` na run = name da tool cuja action abriu (`continue`, `delegate`, `reply`, `send`, `request`).

Default TOML: `concierge` depth 0, `worker` depth 1. Workflow exemplo `delivery` com pelo menos duas etapas.

### Pasta

```text
tools/continue/tool.toml     emit continue   (sem stage)
tools/break/tool.toml        emit break
tools/delegate/tool.toml     emit delegate { title, … }
```

Nenhuma escolhe agent ou model.

### Testes

- Workflow off: `continue` recusa (ou nem entra no ceiling).
- `D0-H0-W1`: work no primeiro stage → `continue` → segundo stage, agent/ceiling novos, `assembled` novo. Último `continue` → `done`, sem run.
- Grant no work + `continue` para stage que `deny` a tool → effective perde a tool; grant permanece na linha.
- `break`: stage igual, run `done`, work `waiting`. `reply` grant (etapa 3) reabre no mesmo stage.
- `D1-H0-W0`: `delegate` → filho + run do `worker`. Pai `waiting = child`. Filho `done` → pai `open`.
- `D1-H0-W1`: filho com workflow próprio ou o mesmo TOML por depth.
- Tool `continue` com `{ stage: "review" }` no emit: store recusa.

## Não fazer

- Hook que anda a sequência.
- Depth 2. `reviewer` (v1.1).
- Processo à espera do filho.

## Pronto quando

`continue` é burro. O TOML é que manda. Filho estaciona o pai.
