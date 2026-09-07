Status: AS-IS — implementado na master

# Arquitetura atual

Omunculus é um harness em Elixir/BEAM. A CLI oferece execução efêmera com
`run`, execução durável com `send` e diagnóstico legado com `monkey-job`
e `benchmark`. Não executa shell por tool nem cria commits.

## Sessão residente

`SessionExecutor` supervisiona Event Core, Projector, Runtime e Automations.
Na CLI compilada, um processo independente protegido por `flock` mantém
um executor por arquivo SQLite. `setsid` permite fechar o cliente sem
encerrar o trabalho. Nas chamadas embutidas, um DynamicSupervisor mantém
o executor na VM da aplicação.

`send`, `session resume` e `inbox reply` garantem o executor. Os clientes
apendam em `EVENTS`; polling por `sequence` entrega appends externos ao
executor vivo. `events follow` acompanha o mesmo log com cursor. Não há
socket de comandos nem mailbox persistente paralela ao log. Arquivos
`.executor-lock`, `.executor-ready` e `.executor.log` são operacionais;
readiness verifica PID e instante de criação do processo.

`send --detach` retorna após o append. Resultado posterior aparece no
`inbox`. Provider, perfil, modelo, limites e caminhos públicos da execução
ficam no payload da tarefa para continuação. Credenciais vêm do ambiente
do executor; não são serializadas no comando persistido.

Ao reiniciar, comandos ainda não iniciados são revalidados e entregues.
Runs interrompidas geram `run.failed` e pedido no inbox para inspeção dos
efeitos antes de um `task.resumed` explícito. Não se repete automaticamente
uma ferramenta cujo efeito após crash seja desconhecido.

## Event Core e projeções

SQLite/WAL usa schema 4 e busy timeout. O Core valida catálogo, deduplica,
faz commit antes da entrega e aplica interceptors. Rejeições permanecem
no log como `delivery.rejected`. O Projector ignora envelopes rejeitados;
uma rejeição tardia reconcilia atomicamente as projeções já adiantadas por
outro cliente. Replay reconstrói as mesmas tabelas.

Audit, DepthGate, TeamGate, ToolGate e WorkspaceGate são interceptors.
TeamGate é obrigatório para pedidos entre linhagens mesmo sem lane.
WorkspaceGate acompanha attach/detach no log da sessão. Automations são
consumidores pós-entrega com cursor reconstruível.

## Runtime e política

Delegar é concluir a Run com checkpoint e `outcome=waiting`. A resposta
abre outra Run, incrementa attempt e restaura o estado. Não permanece
processo bloqueado esperando filho. Pedidos entre linhagens passam pelo
ancestral comum; mediação preserva o checkpoint e permite encaminhar,
reescrever ou negar. O filho registra `requested_by` e dependências.

Config normaliza bandas granted/negotiable/human/forbidden por perfil,
depth, workspace e time. A Run pina a autoridade; tools negociáveis só
executam após concessão. Runtime e ToolGate reconsultam revogações.
Directory e TeamGate compartilham descoberta por identidade real, sessão,
workspace, time e escopo. Roots relativos são resolvidos no diretório do TOML.

`Runtime.Agents` resolve roles, prompts e modelos configurados.
`Chat.Scripts` fornece o comportamento determinístico de `--provider fake`.
`spike` deixou de ser comando público; testes de crash usam o harness.

## Superfície e evidência

O parser nativo usa `CLI.Spec`; `omunculus.usage.kdl` descreve a superfície
portável para usage. Comandos de sessão coexistem com run, monkey-job,
benchmark, events, emit, config, help e version.

A matriz fake cobre vinte combinações. A validação real e seus limites
estão em [fase 7](../spike/phase-7-validation.md). A execução de ferramentas
é verificada separadamente do texto produzido pelo modelo.
