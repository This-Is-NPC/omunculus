# Etapa 8 — Depois

Fecha adaptadores que o spec já descreve e a v1 não inclui: MCP e presets. Permissão custom é pasta, não núcleo.

**Aceite:** sem tool `mcp` genérica. Ligar servidor não amplia ceiling. Preset troca pasta e TOML, não inventa tipo.

## Plano

1. MCP (§8.7): lista de servidores no TOML. Na abertura, `tools/list` → cada tool é um `name` no catálogo. Invoke: `in` → `tools/call` → `out`.
2. Ceiling por name. Servidor ligado ≠ have. Pedir = `request` daquele name.
3. Resource MCP ≠ `view`. Prompt do servidor ≠ `assembled`.
4. Processo do servidor: daemon da pessoa ou só nesta run. Harness não espera.
5. Preset `codex-like` / `pi-like`: TOML + pastas (`bash` só no Codex-like). Mesmas actions.
6. Permissão custom: outra tool, outro `ask.kind`; store classifica `name`.

## Implementação

### Núcleo

- Adaptador no discover da abertura (junto com as pastas). Mesmo `name`: pasta do projeto ganha do MCP.
- Name no ceiling que o servidor não expôs = blocked.
- Sem action nova. Sem tabela nova.
- Preset = conjunto de ficheiros, não branch no ciclo.

### Pasta / config

```toml
[[mcp.servers]]
name = "github"
command = ["npx", "-y", "@modelcontextprotocol/server-github"]
```

Preset: `bash` + agent text + ceiling. Hooks deixam de ser no-op se o preset encaminhar.

Tool custom de permissão: `ask.kind` livre, emit `request`. Sem escrever ceiling.

### Testes

- Dois names do mesmo servidor: um granted, um deny — só o granted no assembled e no sandbox.
- Não existe `tools.mcp({ server, tool, args })`.
- Resource: ou tool à parte que lê, ou ignorado. Não entra em `in.view` sozinho.
- Preset: `bash` have no Codex-like; ausente no default.
- Custom kind: store classifica; grant = `ask.name`.

## Não fazer

- Tipo `mcp` no harness.
- Ampliar effective porque o `tools/list` devolveu mais names.
- Clonar runtime Codex/Pi. Superfície (prompt, tools, ceiling), não o store deles.

## Pronto quando

MCP é discover. Preset é disco. O ciclo da etapa 1 não mudou.
