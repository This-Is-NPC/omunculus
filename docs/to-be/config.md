Status: TO-BE — faixas, modos, grupos, tabela perfil × depth × workspace, policy.loaded, ToolGate e --profile validados; times, may_request/origin e --workspace ainda proposta

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


## Agentes configuráveis e contexto da Run

`concierge`, `repo-concierge`, `worker`, `supervisor` e `reviewer` são agentes
padrão substituíveis por `[agents.<nome>]`. O campo `prompt` define sua identidade,
papel e responsabilidades; alterá-lo substitui integralmente o prompt de papel
padrão. O harness não acrescenta ordens de gerente por nome ou `kind`.
Alterar somente o modelo conserva o prompt padrão.

```toml
[agents.concierge]
prompt = "Você é um gerente. Delegue o trabalho e avalie as evidências recebidas."
tools = ["delegate"]

[agents.worker]
prompt = "Execute a tarefa e relate evidências e pendências no comentário."
tools = ["read", "write"]
max_retries = 1
```

O system prompt contém a identidade configurada e o contrato comum de resposta.
As ferramentas efetivamente autorizadas são expostas pelas suas schemas.
Depth, kind, roteamento, retries e transições são controles internos; não geram
camadas adicionais de prompt. As antigas seções `prompts.depth`, `prompts.kind`
e `prompts.reason` foram removidas.

O contexto de trabalho chega pelo Work Item e pelo comment que inicia a Run.
Instruções do perfil entram no comment inicial da raiz; o agente transmite os
critérios necessários ao delegar. Instruções da etapa ficam no contexto, não no
system prompt. Comentários globais de outros Work Items não são injetados.
Checkpoints preservam a conversa e os vínculos de chamadas de ferramentas.

O contrato `completed/comment` vale para o relatório final e permite chamadas
reais de ferramentas antes dele. `break=true` solicita intervenção. Quem julga
conclusão continua sendo o agente responsável; o harness aplica a decisão.
`max_retries` aceita inteiro >= 0, com precedência agente > perfil > defaults.
Veja [relato, retries e break](run-report-and-break.md).

## Máquina opcional de trabalho

`workflows`, seleção por `workflow` e aprovação da raiz por `root_approval`
estão definidos em [trabalho e aprovação](run-report-and-break.md). A ausência
de máquina não desliga aprovação parental, retries ou break.

## Capacidades do agente

`[agents.<nome>].tools` é uma lista de nomes ou grupos do catálogo, como
`["fs.read", "delegate"]`. A lista restringe a política de perfil/depth/workspace
e as permissões de linhagem; não concede ferramentas acima desse teto.
Ausência conserva a política aplicável; `[]` não permite executar ferramentas.
Nomes desconhecidos ou valores malformados são rejeitados por `config check`.

O reviewer padrão permite `fs.read`, `directory`, `workspaces` e `delegate`,
ainda sujeitos à política. Essa lista é configurável pelo mesmo mecanismo
usado por qualquer agente. A etapa seleciona a configuração por `agent`.
Não há lista especial de ferramentas imposta à avaliação parental.

Em etapas configuradas, as instruções da etapa definem a ação atual; a tarefa
original e seu perfil entram como critérios de referência. Para coordenadores
e avaliações, as instruções do executor também são referências, não ordens
para repetir trabalho. O contexto da nova etapa inclui o estado confirmado
das ferramentas e o comentário do responsável.

Seletores explícitos precisam existir no registro de agentes/times. A
omissão usa os padrões documentados; um nome inventado não seleciona um
worker por fallback. A validação de delegação é aplicada pelo Core mesmo
sem lane configurada e usa a descoberta pinada na Run.

## Interceptação por agente ou ator externo

`[interceptors.<nome>]` pode apontar para `agent = "<nome>"`, reutilizando
`[agents.<nome>]`, ou para `actor = "external:<nome>"`. A regra configura eventos,
contrato da resposta e dependência da continuação. `enabled=false` preserva a
emissão/entrega normal dos novos eventos. Veja o
[contrato e exemplo completos](actor-interception.md).
