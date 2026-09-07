Status: TO-BE — planejado, validado

# Arquivo de configuração

Fonte única do shape do `omunculus.toml`. Os demais documentos usam
trechos deste formato e não definem chaves próprias. Regra geral: **tudo é
opcional, e o padrão é silêncio**. Sem arquivo, o harness se comporta como
hoje: `run <dir>` abre uma sessão efêmera com um workspace igual ao
diretório e todas as tools liberadas.

## Camadas

Três arquivos, mesmo shape, merge por chave: `~/.omunculus/config.toml`,
`omunculus.toml` do projeto, `--config`. O mais específico substitui a
entrada inteira (`[workspaces.x]` do projeto substitui `[workspaces.x]`
global), nunca faz união de listas. A política é relida **antes de cada
Run** ([tool-policy.md](tool-policy.md)); editar o arquivo vale para a
próxima Run.

## Um bloco de política, reutilizado

Onde quer que apareça (workspace, perfil, time, posição), a política tem as
mesmas chaves. Aprende-se uma vez.

| Chave | Valor | Significado |
|---|---|---|
| `mode` | `"allow"` (padrão) ou `"deny"` | onde cai o que não foi citado: `granted` ou proibido |
| `granted` | lista de tools ou grupos | efetivo desde o início |
| `negotiable` | lista | o pai pode conceder |
| `human` | lista | só um humano concede |
| `deny` | lista | proibido, ninguém concede |
| `directory` | `"subtree"` (padrão) ou `"session"` | escopo da tool de descoberta |

Precedência quando a mesma tool aparece em mais de uma lista:
`deny` > `human` > `negotiable` > `granted`. Grupos (`fs.read`, `fs.write`)
expandem na normalização. Detalhes em [tool-policy.md](tool-policy.md).

## Seções

```toml
# ---------------------------------------------------------------- provider
[chat]
api = "openai-completions"
base_url = "http://127.0.0.1:52625/v1"
model = "qwen3.5:4b"
auth = "none"

# ------------------------------------------------------- identidade de agente
# Nada de posição, workspace, time ou tools: só quem o agente é.
[agents.concierge]
prompt = "Você administra a sessão. Nunca faz o trabalho; delega."
model = "qwen3.5:4b"            # opcional; herda de [chat]
max_turns = 8

[agents.worker]
prompt = "Você executa a tarefa com as tools disponíveis e responde curto."

# ------------------------------------------------------------------- times
# Formação: líder, membros, perfil (só estreita), escopo.
[teams.code-review]
lead = "review-lead"
members = ["security-reviewer", "style-reviewer"]
profile = "review"
# scope = "task"  (padrão) | "node"

# -------------------------------------------------------------- workspaces
# Lugar: roots + política inline + times disponíveis.
[workspaces.x]
roots = ["~/x"]
teams = ["code-review"]         # opcional; sem lista, só o time "default"
mode = "allow"
human = ["delete"]

# ----------------------------------------------------------------- perfis
# Interação: instruções + política inline. Absorve os antigos [presets].
[profiles.ask]
instructions = "Responda. Não altere arquivos. Não delegue."
mode = "deny"
granted = ["fs.read"]

[profiles.coding]               # equivalente ao preset coding de hoje
mode = "allow"
deny = ["delegate"]

# -------------------------------------------------------------- posição
# Teto por depth. Ausente = allow. Só quem monta orquestra escreve.
[policy.depth.0]
mode = "deny"
granted = ["delegate", "workspaces", "directory"]
negotiable = ["request_work"]
directory = "session"

[policy.depth.1]
mode = "allow"
negotiable = ["edit", "write", "request_work"]
human = ["delete"]

# --------------------------------------------------------- interceptores
# Tabela por nome. Roda após o commit, antes da entrega; observa ou veta.
[interceptors.depth-gate]
events = ["task.delegated"]
module = "Omunculus.Interceptors.DepthGate"
options = { max_depth = 2 }

[interceptors.infra-readonly]
events = ["tool.call.requested"]
workspaces = ["infra"]          # opcional: só envelopes desse workspace
module = "Omunculus.Interceptors.ToolGate"

# ------------------------------------------------------------ automações
# Tabela por nome. Externas, assíncronas, sem veto.
[automations.notify]
events = ["task.completed", "run.failed"]
run = "./hooks/notify.sh"
may_request = { profiles = ["fix"], workspaces = ["x"] }

# ----------------------------------------------------------------- sessão
# Raramente escrito.
[session]
roles = { depth0 = "concierge", depth1 = "concierge", depth2 = "worker" }
cross_lineage = "routed"        # ou "mediated"
tools_catalog = "1"             # pin: tools mais novas ficam proibidas em allow

# ------------------------------------------------------------------ saída
[output]
timestamp_format = "%H:%M:%S"
```

## Convenções que substituem chaves

| O que não se escreve | Vale |
|---|---|
| `[policy.depth.N]` | `allow` sem exceções |
| profundidade máxima | maior `N` escrito em `policy.depth`, senão 2 |
| `[session].roles` | `depth0 = concierge`, `depth1 = concierge`, `depth2 = worker` |
| time de um workspace | `default`: líder `concierge`, membros `worker` |
| `[teams.x].scope` | `task` |
| `[session].cross_lineage` | `routed` |
| time com um agente só | o nome do agente serve como time |
| `mode` | `allow` |
| `directory` | `subtree` |
| `[agents.x].model` | o de `[chat]` |
| perfil de um `send` | `coding` |

## Compatibilidade

- `[presets.x]` é aceito como sinônimo de `[profiles.x]` e `--preset` de
  `--profile`, até a próxima versão maior.
- `[[interceptors]]` e `[[automations]]` com `name` são aceitos como
  sinônimo das tabelas por nome.
- `[defaults]` continua existindo para `preset` e `max_turns`.

## Três níveis de uso

**Zero config.** `omunculus run . "…"`. Igual a hoje.

**Um repositório, alguns modos.** Dez linhas:

```toml
[workspaces.app]
roots = ["."]

[profiles.ask]
instructions = "Responda sem alterar arquivos."
mode = "deny"
granted = ["fs.read"]
```

**Orquestra.** Acrescenta `agents`, `teams`, `policy.depth`, interceptores
e automações, como no exemplo completo acima. Só quem monta times escreve
isso.

## Validação

`omunculus config check` normaliza tudo, imprime as faixas expandidas para
cada perfil × depth × workspace, e falha em: tool ou grupo inexistente no
catálogo, perfil que não cabe em teto algum, agente referenciado por time
ou papel sem `[agents.x]`, time referenciado por workspace sem
`[teams.x]`, interceptor com tipo não interceptável ou módulo ausente,
automação sem `run`, `may_request` apontando para perfil ou workspace
inexistente.
