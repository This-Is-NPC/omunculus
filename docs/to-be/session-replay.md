Status: implementado — UIs selecionáveis, banco compartilhado e seleção obrigatória por session_id; detalhes em [validação](../spike/shared-session-validation.md).

# Histórico de sessão na mesma UI do run

## Objetivo e decisões

Imprimir no terminal o histórico completo de uma sessão usando a mesma UI
utilizada durante `run`. Permitir analisar tanto o comportamento dos agentes
quanto a apresentação da execução, sem chamar modelos, executar ferramentas
ou retomar trabalho. O replay apresenta fatos; não avalia a qualidade da tarefa.

Uma única implementação de apresentação atende execução ao vivo e histórico.
A fonte muda: eventos persistidos que chegam durante a execução, ou leitura
ordenada desses mesmos eventos. Não criar um renderer exclusivo para replay,
um segundo log de UI, formatos legados ou reconstruções heurísticas de transcript.

Referências: [sessão](session-model.md), [eventos](event-model.md),
[catálogo](event-catalog.md), [execução](execution-model.md) e
[relato e break](run-report-and-break.md).

## Situação anterior à implementação

Base inspecionada antes da implementação: `be17bed`.

- `CLI.run` chama `CLI.Session.ephemeral_run`: inicia Event Core e Runtime,
  imprime o resultado final e remove o banco temporário. Não liga a UI detalhada.
- `Runner.start` liga `Agent.run` a `CLI.Reporter`, que já desenha cabeçalhos,
  rodadas, ferramentas e tabelas. Seu estado é de uma Run e ele encerra quando
  essa Run termina. Não atende sozinho uma sessão com Runs intercaladas.
- `Runtime.Run.report` persiste métricas de `round_completed` como
  `model.call.completed`. Não persiste todo o conteúdo enviado/recebido ali.
- Checkpoints contêm mensagens, mas repetem contexto entre Runs e não garantem
  uma cronologia completa de cada interação, especialmente antes de uma falha.
- Rejeições anteriores à execução, como `handoff_comment_required`, podem
  aparecer apenas nas mensagens do checkpoint. A validação local encontrou
  nove dessas respostas que uma contagem de eventos de execução não capturaria.
- `events follow --once` imprime envelopes em NDJSON; não usa `CLI.Reporter`.
- Abrir `EventCore` normalmente inicializa armazenamento e mecanismos de
  execução. Esse caminho não serve como leitor estritamente passivo.

Portanto, apenas conectar o banco ao Reporter atual não satisfaz o objetivo.

## Comando e comportamento

```sh
omunculus session replay <session_id> --db ./session.sqlite3
omunculus session replay <session_id>
omunculus session replay <session_id> --db ./session.sqlite3 > historico.txt
```

Usar a resolução de caminho existente: `--db`, `--session` (caminho),
`OMUNCULUS_SESSION` e banco padrão `~/.omunculus/session.sqlite3`, respeitando
as precedências atuais. Não adicionar busca por ID nem catálogo de arquivos.
O `session_id` é o argumento obrigatório que seleciona a sessão no banco. Sem ID,
retornar erro de uso; ID desconhecido retorna erro de leitura, sem imprimir dados
de outras sessões. `session list --db arquivo.sqlite3` lista todos os IDs registrados,
em ordem de criação. Não escolher implicitamente a primeira ou a última sessão.

Um banco contém várias sessões. Cada teste cria um evento `session.created` com
o mesmo ID no envelope e no payload; todos os seus eventos carregam esse ID.
O replay filtra por `EVENTS.session_id`, preservando a sequência global original.
Não agrupar por Run nem reconstruir a sessão por semelhança de instruções.

O comando lê todo o prefixo disponível na abertura, em `sequence` crescente,
imprime imediatamente e termina. Não espera a duração histórica nem acompanha
novos eventos. O limite superior de sequência da sessão selecionada é fixado em um snapshot de leitura
SQLite consistente, inclusive quando outra execução está escrevendo em WAL.
Não copiar apenas o arquivo principal e perder eventos ainda no WAL.

A saída do histórico vai integralmente para stdout; erros do comando vão para
stderr. `> historico.txt` captura toda a apresentação sem códigos de controle.
Em terminal, usar os mesmos componentes visuais do modo ao vivo, com identificação
“Replay”, timestamps gravados e sem spinner ou relógio de execução ativo.

Exit codes: `0` se o histórico foi lido e apresentado; `1` para erro de leitura,
banco inválido ou contrato não suportado; `2` para uso inválido da CLI. Uma tarefa
failed, pendente ou escalada não muda o exit code de uma leitura bem-sucedida.

## Conteúdo obrigatório

O modo `--detail full` inclui o conteúdo registrado completo, sem truncamento.
O padrão `--detail normal` mostra início/fim das Runs, rodadas, respostas,
ferramentas e coordenação; omite prompts, schemas e checkpoints repetidos:

| Informação | Apresentação |
| --- | --- |
| Sessão e workspace | Identidade, caminhos registrados e limites de sequência |
| Pedido humano | Instrução original e respostas posteriores da inbox |
| Run | ID, Work Item, parent, depth, kind, agente, modelo, motivo e etapa |
| Contexto do modelo | System prompt efetivo, mensagens e schemas enviados em cada chamada |
| Resposta do modelo | Conteúdo retornado ao harness, chamadas estruturadas, uso e duração disponíveis |
| Ferramenta | ID da chamada, nome, argumentos, retorno ou erro, inclusive rejeições antes do efeito |
| Coordenação | Delegação solicitada, aceitação/rejeição, filho criado e resultado recebido |
| Julgamento do responsável | `completed`, `comment`, alvo avaliado e solicitação de correção |
| Fluxo | Avanços, conclusão, retries, break e pedido/resposta de intervenção humana |
| Encerramento | Desfecho registrado e resumo por Run, sem confundir Run encerrada com tarefa concluída |

Mostrar `status` e `state` conforme as entidades e eventos registrados, com
rótulos distintos. Uma solicitação de delegação rejeitada não cria visualmente
um filho; um comentário dizendo “stage advanced” não substitui `task.advanced`.
Nenhum efeito, aprovação ou conclusão é inferido do texto do modelo.

`timeline` identifica timestamp, `sequence` e Run em cada evento. Os cabeçalhos
das três UIs identificam Work Item e relações registradas; `full` inclui todas as identidades. Runs
concorrentes permanecem intercaladas na ordem do log; cabeçalhos/contexto de
identidade impedem misturar suas rodadas. O estado do renderer é separado por
`run_id`, e o fim de um filho não encerra o renderer da sessão.

Eventos sem componente específico são apresentados com seu tipo e payload
no modo normal; `full` apresenta o envelope inteiro. Não descartá-los
silenciosamente. Esse componente também pertence à UI compartilhada.

“Completo” significa todo conteúdo disponível ao harness e persistido: não inclui
raciocínio interno não fornecido pelo provider nem reprodução dos pixels de uma
versão antiga da UI. A UI atual renderiza a sessão; alterações nela devem aparecer
tanto ao vivo quanto no replay. Campos ausentes são “não registrados”, nunca zero,
horário atual ou dados obtidos da configuração atual.

## Persistência necessária

Estender o catálogo atual e os pontos de emissão, mantendo `EVENTS` como fonte:

1. Registrar `model.call.requested` antes de chamar o provider, com identidade
   estável da chamada, rodada, modelo, mensagens efetivas e schemas de ferramentas.
2. Completar `model.call.completed` com essa identidade e a resposta estruturada
   recebida pelo harness, preservando argumentos originais das tool calls.
   Registrar `model.call.failed` com a mesma identidade em falhas de transporte
   ou parsing. Não fabricar resposta quando o provider não a forneceu.
3. Fazer `tool.call.requested` e `tool.call.completed` cobrirem cada tentativa,
   incluindo validação de comentário, negação de política, seletor inválido e
   handoff aceito. Registrar argumentos, ID da tool call e o resultado realmente
   devolvido ao agente. Distinguir tentativa, efeito executado, erro e espera.
4. Reutilizar os eventos existentes de ciclo de Run, julgamento e transições.
   Completar somente metadados ausentes necessários à apresentação.

Ajustar os emissores existentes; não adicionar pares duplicados de eventos para
uma mesma chamada. Os eventos de tool devem manter seu papel de autorização e
causação: antecipar o registro da tentativa não autoriza executar uma tool negada.
O handoff termina a Run conforme o protocolo, sem esperar sincronicamente o filho.

O request persistido representa o input efetivo no limite do adaptador do provider,
sem headers de autenticação, API keys ou dump do ambiente. Não persistir uma cópia
do objeto de configuração com credenciais. Captura HTTP bruta e diagnóstico do
parser do servidor são outro escopo; não prometer que o transcript os contém.

Persistir antes de apresentar: a UI ao vivo consome o mesmo envelope confirmado
que o replay lerá. Checkpoints continuam servindo à retomada, não viram um segundo
formato de histórico. Não deduplicar mensagens por igualdade de texto: repetições
reais do modelo são evidência e precisam permanecer visíveis.

Não migrar bancos antigos, sintetizar eventos faltantes ou implementar leitores
para contratos anteriores. Eventos do contrato atual com informação não capturada
podem ser exibidos como registrados; sinalizar as lacunas. Um contrato incompatível
é recusado explicitamente. A aceitação do histórico completo usa sessões novas
criadas com a instrumentação implementada.

## Integração e retenção

Evoluir `CLI.Reporter` para consumir a apresentação derivada de envelopes do Event
Core e manter o estado de múltiplas Runs. Separar a preparação comum dos eventos dos módulos de layout; remover a
formatação de envelopes substituída. Os três layouts não duplicam leitura,
interpretação de eventos ou execução.

Ligar o `run` a esse caminho comum. O leitor do replay apenas consulta o banco,
sem Runtime, SessionExecutor, interceptores, automações, append, migração ou rebuild
de projeções. Reutilizar a consulta/decodificação existente onde possível e expor
abertura realmente somente leitura no armazenamento. Banco inexistente é erro;
a leitura não cria arquivo nem altera o banco/projeções/inbox.

Para analisar posteriormente uma execução de `run`, oferecer retenção explícita:

```sh
omunculus run ./projeto "instrução" --db ./execucao.sqlite3
omunculus session replay <session_id> --db ./execucao.sqlite3
```

Nesse modo, acrescentar uma sessão nova ao banco, preservá-la inclusive em falha
e informar o ID e o caminho. Um arquivo existente é reutilizado sem sobrescrever
ou misturar sessões. Sem `--db`, manter a sessão efêmera já definida. Sessões duráveis de `send` continuam usando seu banco.
Não introduzir registry, política de rotação ou serviço de replay.

## Plano de implementação

1. Instrumentar chamadas completas e rejeições no contrato único de eventos;
   atualizar catálogo e testes de causação/autoridade afetados.
2. Conectar a UI compartilhada ao log, suportar Runs intercaladas e conteúdo
   completo; integrar `run` e a retenção explícita do banco.
3. Implementar leitor somente leitura e `session replay`, parser e help.
4. Validar os critérios abaixo e registrar exemplos de uso reais.

Fora desta entrega: player com pausa/velocidade, seleção de subárvore, filtros,
follow contínuo, exportador adicional e retomada/intervenção pelo replay.
A primeira versão deve resolver leitura integral e revisão da UI sem essas camadas.

## Critérios de aceitação

- Uma sessão nova com delegação, review e conclusão produz a mesma sequência
  de blocos de conteúdo ao vivo e no replay, usando o mesmo renderer. O teste
  normaliza apenas cabeçalho de modo e efeitos transitórios do terminal.
- Cenário com Runs intercaladas preserva ordem global, identidade e contadores
  por Run; cada evento aparece uma vez e cada fechamento encerra somente sua Run.
- Rejeição por `comment` ausente, agente inexistente e política negada mostra
  argumentos e erro completos, sem filho ou efeito inventado. Retry e break
  aparecem até o pedido humano, sem registrar sucesso inexistente.
- Falha de provider mostra o request confirmado e a falha; não uma resposta
  fabricada. Dados ausentes em um registro são explicitamente identificados.
- EOF com Run aberta mostra “sem encerramento registrado neste histórico”, sem
  afirmar que o processo segue vivo ou que a tarefa falhou. Uma sessão com novas
  escritas durante a leitura termina no limite de sequência capturado.
- Replay funciona sem API key, rede, workspace original ou executor ativo.
  O banco e suas projeções permanecem intactos; nenhuma chamada de modelo,
  ferramenta, automação, leitura de inbox com marcação ou rebuild ocorre.
- Redirecionamento com `--detail full` captura prompts, respostas, erros e conteúdo extenso completos,
  sem ANSI ou truncamento silencioso. Timestamps e durações vêm do registro.
- `run --db` preserva a sessão e a UI; duas execuções no mesmo banco geram IDs distintos. Replay de
  arquivo inexistente não cria banco. Help e exit codes seguem o contrato acima.

Testes determinísticos com provider fake e captura de IO verificam equivalência,
completude e ausência de efeitos. Um smoke test com provider real gera um banco
novo para revisão manual da UI, sem usar duração como critério de sucesso da tarefa.

## Implementação entregue

`session replay <session_id> --db` abre SQLite somente leitura, fixa o snapshot da sessão e percorre
o log em lotes de 256 envelopes. Usa `CLI.Reporter` e `CLI.UI`, a mesma
apresentação selecionável usada pelo `run`. O estado visual é separado por Run.
O antigo dump seguido de uma segunda apresentação da mesma Run foi removido.

O modo ao vivo usa notificações de entrega para ler o prefixo confirmado do log:
isso inclui solicitações rejeitadas que não são entregues aos executores. O fim
da apresentação drena o restante desse prefixo. Campos de conteúdo não são
truncados. `normal` seleciona conteúdo; `full` inclui o envelope completo.

Os eventos de modelo incluem request, resposta ou falha. O `event_id` do request
é a identidade da chamada, referenciada por `call_id` e `causation_id` no resultado.
Tentativas de ferramentas têm `tool_call_id`, argumentos, resultado, duração e
outcome `completed`, `waiting` ou `error`. A identidade do envelope distingue
tentativas mesmo quando um provider reutiliza IDs. Falhas não registram novos
valores de contador. `control_tools` em `run.started` pina as ferramentas de
permissão/arbitragem para preservar sua autorização ao passarem pelo ToolGate.

`run --db` conserva o banco e cria uma sessão nova mesmo quando o arquivo já existe. O cliente efêmero retorna
quando a raiz solicita avaliação humana, preservando o registro nesse modo;
a API de espera usada por sessões residentes mantém a espera pela resposta humana.

Sessões são selecionadas por identidade registrada. Não atribuir IDs retroativos
a logs sem `session.created`/`session_id`, nem copiar automaticamente bancos antigos.
Não há migração ou leitor de formatos antigos nesta entrega.

## Isolamento entre sessões no banco

O banco é a unidade de armazenamento; a sessão é a unidade de execução/contexto.
`EVENTS` tem índice `(session_id, sequence)`. `Runtime` aceita `session_id` para
restringir assinatura, recuperação, avaliações pendentes e continuações. Os testes
reais usam esse escopo explicitamente para cada cenário. Um runtime administrativo
sem esse escopo continua podendo atender várias sessões do mesmo banco.

Workspaces são projetados por `(session_id, workspace_id)`: attach/detach em uma
sessão não altera o workspace homônimo de outra. Descoberta, roots e consulta de
policy.loaded respeitam a sessão. Decisões e falhas preservam a identidade no envelope.

Os scripts `validate_workflow.exs`, `validate_real_matrix.exs` e
`validate_parent_review.exs` gravam campanhas em `test/sessions.sqlite3`
por padrão; `--db` seleciona outro banco. Cada cenário gera um ID e o imprime junto
do Work Item raiz. Resultados JSON incluem `session_id` e `database`; métricas e
observação são restritas à sessão. Os diretórios temporários guardam configurações
e relatórios, não um banco separado por cenário.

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/cloud.toml --db test/sessions.sqlite3
omunculus session list --db test/sessions.sqlite3
omunculus session replay <session_id> --db test/sessions.sqlite3
```

## Protótipos de apresentação

`run` e `session replay` aceitam `--ui blocks|timeline|tree|narrative` e
`--detail normal|full`. Padrões: `blocks`, `normal`. Valores inválidos retornam
2 antes de abrir o banco ou iniciar execução. `run --json-events` conserva NDJSON
como saída de máquina e tem precedência sobre a apresentação visual.

- `blocks`: abertura e fechamento explícitos, separadores horizontais sem borda
  vertical, conteúdo indentado e marcador
  de retomada visual quando eventos de outra Run intercalam a exibição.
- `timeline`: timestamp e sequência originais, com Run identificada em cada evento.
- `tree`: fluxo cronológico indentado pelo depth registrado; cabeçalhos mostram
  Work Item, Parent Work Item, Parent Run e Originating Run. Delegações e avaliações
  aparecem na ordem real. Não reorganiza eventos em subárvores contíguas.

Todos imprimem progressivamente e preservam a ordem do log, inclusive no replay.
Não há buffering de uma Run inteira: uma execução aberta permanece observável.
Um fim `reported` ou `waiting` descreve a Run; aprovação e avanço de tarefa
continuam sendo eventos próprios. EOF sem fechamento não implica processo vivo.

Para adicionar uma UI, ver [guia de layouts](../cli-ui.md).

As UIs quebram texto na largura do terminal antes da impressão, repetindo o
recuo e, em timeline/tree, a borda esquerda nas continuações. Saída redirecionada
usa 100 colunas. As quebras não descartam conteúdo, inclusive em `full`.

Todas as UIs terminam com a mesma tabela de analytics da sessão: intervalo
registrado, Runs, profundidade, Work Items, delegações, avaliações, avanços/breaks,
chamadas de modelo/ferramentas, tokens, custo registrado e tempos acumulados.
A tabela é calculada apenas do prefixo lido, com valores ausentes/parciais explícitos,
e segue as regras de [agregação compartilhada](../cli-ui.md#resumo-da-sessão).

### Narrative

`--ui narrative` é uma quarta apresentação, inspirada na primeira UI do CLI
(`9266877`). Exibe ações numeradas com START/END, Runs e Work Items com referências
curtas e eventos atômicos com DONE. Pares de chamadas usam event_id/causation_id;
avaliações usam request_id. Encerramento da Run, avaliação e avanço da tarefa
permanecem eventos distintos. A ordem cronológica e os dados registrados nunca
são reescritos para produzir uma narrativa. Detalhes em [guia das UIs](../cli-ui.md#view-narrative).
