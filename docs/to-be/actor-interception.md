# Interceptação por atores

O evento original é emitido e persistido independentemente da interceptação.
Uma regra habilitada acrescenta uma interação; desabilitada, não cria solicitação
nem dependência. Atores não executam dentro do Event Core. Não existe uma ação
especial de resumo no runtime: identidade, instrução e ferramentas vêm da config.

## Configuração

O shape de agente continua sendo `[agents.<nome>]`. Exemplo completo em
[`examples/interception-agent.toml`](../../examples/interception-agent.toml).

```toml
[agents.handoff-editor]
prompt = "Produza contexto a partir do evento recebido, preservando evidências e pendências. Não execute nem aprove a tarefa original."
tools = []
workflow = false

[interceptors.handoff-context]
events = ["run.completed"]
match = {outcome = "reported"}
agent = "handoff-editor"
work_item = {instruction = "Prepare o comment para a próxima Run."}
response = {comment = "string"}
bindings = {"report.comment" = "comment", "comment" = "comment"}
wait = true
enabled = true
max_retries = 1
```

Para um ator externo, substitua `agent` por `actor = "external:handoff-editor"`.
O identificador é um endereço lógico para o consumidor da porta de eventos, não
um módulo ou uma URL executada pelo Core. `agent`, `actor` e `module` são seletores
mutuamente exclusivos. `module` continua disponível para os gates locais de
política; eles não executam chamadas de modelo. Regras de ator passam pelos gates
antes de abrir uma solicitação, preservando a autoridade das políticas.

| Campo | Contrato |
|---|---|
| `events` | Tipos do catálogo que disparam a regra |
| `match` | Igualdade em caminhos do payload, separados por ponto |
| `workspaces` | Restrição opcional por workspace |
| `agent` / `actor` | Agente configurado ou consumidor externo |
| `work_item` | Definição da tarefa de processamento, com `instruction` |
| `response` | Campos obrigatórios e tipos: string não vazia, boolean, number, object, array |
| `bindings` | Campo do resultado para campo de contexto da entrega |
| `wait` | `true` aguarda o resultado; `false` observa sem segurar a entrega |
| `enabled` | `false` não abre novas interações |
| `max_retries` | Repetições da interação depois da primeira tentativa |
| `timeout_ms` | Prazo opcional da resposta do ator; ausente significa sem prazo |

As bindings são declarativas: destino à esquerda e campo da resposta à direita.
Os destinos atuais são `comment`, `report.comment` (em `run.completed`) e `result` (em `task.completed`), todos textuais.
Não podem alterar IDs, estado, ferramentas ou `completed` da tarefa original.
Isso delimita o contrato de contexto sem ensinar ao harness o que um resumo deve
conter. Agentes e atores externos respondem pelo `response` configurado. O agente recebe
esse contrato no system prompt e retorna apenas seus campos; aqui, `{"comment":"..."}`.
Não recebe o contrato de execução `completed/comment/break`. O Core valida os tipos
do output, sem julgar a tarefa descrita no evento.

Com `wait=false`, bindings devem ser vazias: uma observação assíncrona não altera
retroativamente uma entrega realizada. Várias regras recebem o evento original;
as respostas podem chegar fora de ordem. A aplicação das bindings respeita a
ordem das solicitações/configuração, aguardando todas as regras dependentes.

A suspensão é suportada nas fronteiras de ativação/continuação:
`task.requested`, `task.delegated`, `task.resumed`, `run.completed`, `run.failed`,
`task.run_requested`, `task.advanced`, `task.assessment_requested`, `task.break`
e `task.completed`. Outros eventos podem ser observados com `wait=false`.
Uma pausa arbitrária dentro de uma chamada de ferramenta/modelo não é anunciada
como suportada: exige checkpoint e retomada próprios do consumidor.

## Protocolo persistido

1. O Core persiste o evento de origem, intacto.
2. `interception.requested` registra origem, regra efetiva, ator, tentativa,
   Work Item do ator e eventual prazo. O processamento fica fora do Core.
3. O ator publica `interception.responded`, correlacionado à solicitação, com
   `outcome=completed` e `output`, ou `outcome=failed` e `error`.
4. O Core valida o contrato. Sucesso registra `interception.resolved`; falha abre
   a próxima tentativa até o limite. Esgotamento cria solicitação para `human`.
5. Resolvidas as dependências, o evento original é entregue. O consumidor de
   execução obtém o contexto pela visão de entrega, derivada das resoluções.

`EventCore.stream` e `fetch` mostram o histórico original. `delivery` e
`delivered_stream` são a visão de execução: excluem dependências pendentes e
aplicam somente o contexto autorizado. Runtime e recuperação usam essa visão, inclusive para atualizar o comment nos checkpoints de retomada;
projeções e replay mantêm os fatos originais e os eventos de resolução.
O fechamento factual de uma Run continua visível para detectar processos
interrompidos: aguardar interceptação não transforma uma Run encerrada em crash.

Uma delegação pendente encerra a Run solicitante normalmente como `waiting`.
Ela não mantém um processo esperando pelo ator. A futura Run filha nasce quando
a entrega é liberada. Atores agentes têm Work Items e Runs próprios, com uma
correlação própria e `causation_id` vinculado à solicitação. Uma resposta válida encerra a Run com `outcome=responded` e `output`; o adaptador
registra a conclusão do Work Item de processamento e publica a resposta da interação.
Isso não aprova a tarefa original. Eventos dessa linhagem não voltam
à interceptação por atores, evitando recursão acidental; gates de política
continuam valendo.

## Falhas, prazos e reinício

O orçamento da interação é persistido por evento de origem/regra. Cada tentativa
executa uma Run do ator, sem workflow de aprovação ou retries internos do Work Item.
Falha técnica, limite de execução ou resposta inválida produz falha da interação;
seu `max_retries` é o único orçamento de repetição. Esgotamento escala para `human`.
Uma descrição válida de uma tarefa que falhou resolve a interação normalmente.
O agente de processamento não decide conclusão ou correção da tarefa original;
o pai continua responsável por avaliá-la. Reiniciar o Core não renova o orçamento.

Se configurado, o vencimento gera `interception.expired`, identificado como ação
do Core, não uma resposta fictícia do ator. Usa o mesmo caminho de recuperação.
Não julga a conclusão da tarefa por segundos decorridos. Solicitações humanas
não expiram automaticamente. Sem prazo, ausência de resposta mantém a dependência
persistida; o ator pode responder depois ou registrar falha pela porta de eventos.

Respostas com ator/correlação incorretos ou output incompatível são rejeitadas.
Uma resposta já aceita/expirada não aceita outra resposta concorrente; repetir o
mesmo envelope é idempotente. Respostas tardias não liberam a passagem. O cursor
de entrega e o snapshot da regra recuperam tanto interrupção após o commit da
origem quanto após o commit da resposta, antes de registrar sua resolução.
Desativar uma regra afeta novos eventos; interações já abertas mantêm o contrato
persistido e precisam de resolução explícita.

O endereço lógico do ator identifica o roteamento. A porta local de escrita já
é uma autoridade confiável; esse campo não implementa autenticação de rede.

## Porta externa

```sh
./omunculus events follow --db test/sessions.sqlite3 --types interception.requested
./omunculus emit interception.responded --db test/sessions.sqlite3 --request-id int-ID --payload '{"actor":"external:handoff-editor","outcome":"completed","output":{"comment":"Evidências e próximos passos."}}'
```

`--request-id` preenche sessão, Work Item e correlação a partir da solicitação.
Em caso de falha, envie `outcome=failed` e `error`. Na escalada, o destinatário
passa a `human`, que responde pelo mesmo contrato. O mesmo protocolo serve a
qualquer processo externo que leia a porta e publique a resposta; o Core não
executa um script de resumo ou chama uma API de modelo.

## Verificação

`test/omunculus/interception_test.exs` cobre ator externo, agente configurado,
configuração desativada, observação, respostas inválidas/duplicadas/tardias,
respostas fora de ordem, retry, prazo, escalonamento e recuperação nos intervalos
entre commits e entrega. Verifica também o comment recebido pelo pai e replay.

```sh
mise exec -- mix run scripts/validate_interception.exs presets/local.toml
```

O cenário real executa um incremento, processa seu evento com o agente
`handoff-editor` e executa uma Run de review. Mede efeitos, fechamento das Runs,
resoluções e se o reviewer recebeu o comment depois da resolução, sem prazo de
sucesso/fracasso da tarefa.

## Exclusões na entrega do evento

A regra do interceptor pode excluir campos da representação do evento entregue
ao ator. O `run.completed` original permanece íntegro no banco para replay e
outros consumidores. Não há campo `input` no pedido nem uma cópia adicional do
evento persistida nele. `source_event_id` identifica a fonte; a regra persistida
no pedido determina as exclusões, inclusive nas novas tentativas.

```toml
[interceptors.handoff-context]
events = ["run.completed"]
agent = "summarizer"
work_item = {instruction = "Summarize the recorded execution evidence."}
response = {comment = "string"}
bindings = {"comment" = "comment", "report.comment" = "comment"}
exclude = ["payload.comment", "payload.report"]
exclude_items = [
  {path = "payload.checkpoint.messages", match = {role = "assistant"}, missing = ["tool_calls"]}
]
```

`exclude` remove caminhos com pontos em objetos do envelope. `exclude_items`
remove itens da lista em `path` quando todos os pares de `match` correspondem às
propriedades diretas do item e todos os campos de `missing` estão ausentes/nulos.
Pelo menos um critério é necessário. Caminhos ausentes não provocam erro. Não há
wildcard, índices de array nem avaliação de expressões.

Esse exemplo retira comentário, relatório e respostas do assistant sem tool calls,
inclusive respostas anteriores à correção de formato. Preserva solicitações de
tools, retornos e estado confirmado. Comentários históricos dentro das mensagens
de contexto permanecem. A fonte continua sendo o evento de conclusão e seu
checkpoint; não é uma coleta de todos os eventos da sessão.

Agentes locais recebem diretamente esse evento filtrado no comentário inicial.
Atores externos usam a mesma entrega pelo pedido correlacionado:

```sh
omunculus events show --request-id INTERCEPTION_REQUEST_ID --db test/sessions.sqlite3
```

A saída é o próprio envelope `run.completed`, com as exclusões aplicadas. O log
bruto em `events follow` permanece íntegro. A seleção é de contexto, não de acesso.

Comparação com Qwen:

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml plain --depth 1 --interceptor on --interceptor-input full
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml plain --depth 1 --interceptor on --interceptor-input without-report
```
