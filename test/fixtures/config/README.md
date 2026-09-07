# Fixtures de configuração

Configurações no shape de `docs/to-be/config.md`, uma por nível da matriz de
`docs/spike/event-core-spike.md`. Combinam-se pelo layering do `Config`:
base + `lane.toml` (interceptores) dá a variante "com lane".

| Arquivo | Nível | Depth | Times | Workspaces |
|---|---|---|---|---|
| `simple.toml` | harness de mercado: um agente, tools de arquivo, sem delegação | 0 | — | 1 (cwd) |
| `medium.toml` | concierge delega a workers | 1 | `default` | 1 |
| `medium-teams.toml` | concierge roteia por tipo de tarefa | 1 | `count`, `edit` | 1 |
| `complex.toml` | dois repos, faixa `human`, automação | 2 | `default` | 2 |
| `complex-teams.toml` | times por workspace, `request_work` pelo LCA | 2 | por workspace | 2 |
| `lane.toml` | overlay: `audit`, `depth-gate`, `tool-gate`, `team-gate` | — | — | — |

Tarefas fixas para todas as combinações: **contar até 10** (tool `counter`)
e **escrever um README** (`FS.Memory`, tools `fs.write`).

Os perfis `coding` e `count` dos fixtures com times permitem a delegação
inicial: a política do depth 0 limita o concierge às tools de coordenação.
`medium-teams` define também o teto do depth 1, sem nova delegação.
A matriz completa usa essas políticas diretamente, sem sobrepor perfis
permissivos. Cenários específicos de trabalho entre times usam overlays
explícitos de concessão e descoberta; testes negativos preservam `subtree`
e a faixa negociável para provar que não autorizam acesso implícito.
