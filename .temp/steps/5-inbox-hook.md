# Etapa 5 — Inbox e hook

Fecha aviso ao humano e hook que só reage.

**Aceite:** `D0-H1-W0`. Notify não trava. Inbox ≠ request. Hook não abre run.

## Plano

1. `notify` cria `INBOX` + comment + `EVENTS(notify)`. Run segue. Work não espera.
2. CLI: `inbox` lista sem `read_at`. `inbox_read` marca `read_at`. Comentar no inbox (`inbox_id`) não vira request.
3. Hooks: pastas `hook.toml` + `run`. `events = ["request"]` etc. Depois do emit, o harness chama os hooks daquele `type`.
4. Hook pode chamar um agente (run igual). Isso não sequencia. Quem abre a próxima run do protocolo continua a ser a action.
5. Default dos quatro hooks: no-op. `RUNS.via` = name do hook só quando o hook foi quem chamou o agente.

## Implementação

### Núcleo

- Action `notify`: `INBOX`, comment do agente, event. Sem mudar `waiting`. Sem end-run.
- Action `inbox.read`: `read_at` agora.
- Função de view: lista inbox (filtro sem `read_at` para a tool `inbox`).
- Depois de `apply`: carregar hooks com aquele `events` type; invoke o mesmo contrato; `emit` do hook passa pelo store (regras iguais). Se o hook não emitir action que pede run, o fluxo segue.
- Configurar hook → agent: TOML do hook ou do event aponta o agent; harness abre run **se a action do hook pedir** (ou se o manifesto do hook declarar “chama agent X” — o spec diz: hook configurado para chamar um agente ganha uma run igual). Implementar: manifesto `agent = "…"` no hook → depois do hook, se não houver action de sequência, abrir essa run como reação, `via` = name do hook. A action do protocolo (se houver) ainda é quem segue o work.
- Não deixar o hook emitir `continue` “por baixo”: pode emitir se o ceiling do hook/agent tiver a tool — é uma run, não um atalho no núcleo.

### Pasta

```text
tools/notify/tool.toml           triggers = ["model"]
tools/inbox/tool.toml            triggers = ["cli"]   view: INBOX sem read_at
tools/inbox_read/tool.toml       triggers = ["cli"]   emit inbox.read
tools/on-request/hook.toml       events = ["request"]   run no-op
tools/on-notify/hook.toml        events = ["notify"]
tools/on-continue/hook.toml      events = ["continue"]
tools/on-break/hook.toml         events = ["break"]
```

### Testes

- `notify` no meio da run: linha `INBOX`, run continua, work `open`.
- `inbox` / `inbox_read`: lista só não lidos; depois some. Comment com `inbox_id` não cria `REQUESTS`.
- `D0-H1-W0`: event com hook no-op — ciclo igual a H0, mais a call do hook (event de tool/hook no log).
- Hook que chama agent: run extra `via = on-request` (ou o name). Depois, se a action `request` já ia abrir o arbiter, não duplicar: um hook no-op + action abre o arbiter; hook com agent é o caso “reagir com outra run”.
- Hook não substitui `continue`. Sem emit `continue`, o stage não anda.

## Não fazer

- Transformar hook em sequencer.
- Pedido de decisão em `INBOX`.
- MCP.

## Pronto quando

Avisar é inbox. Decidir é request. Hook aparece no log e não escolhe a próxima etapa.
