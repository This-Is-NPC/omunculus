Status: implementado — validado com 319 testes e smoke com Qwen local; detalhes em [validação](../spike/session-replay-validation.md).

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
omunculus session replay --db ./session.sqlite3
omunculus session replay
omunculus session replay --db ./session.sqlite3 > historico.txt
```

Usar a resolução de caminho existente: `--db`, `--session` (caminho),
`OMUNCULUS_SESSION` e banco padrão `~/.omunculus/session.sqlite3`, respeitando
as precedências atuais. Não adicionar busca por ID nem catálogo de arquivos.
O `session_id` é exibido como identidade, não interpretado como caminho.
Um banco representa uma sessão; logs de testes sem `session.created` são
identificados pelo caminho e mostram “session_id não registrado”.

O comando lê todo o prefixo disponível na abertura, em `sequence` crescente,
imprime imediatamente e termina. Não espera a duração histórica nem acompanha
novos eventos. O limite superior de sequência é fixado em um snapshot de leitura
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

A apresentação padrão do replay inclui o conteúdo registrado completo, sem
truncar silenciosamente prompts, argumentos, respostas ou comentários:

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

Cada bloco identifica `sequence`, Run e Work Item quando presentes. Runs
concorrentes permanecem intercaladas na ordem do log; cabeçalhos/contexto de
identidade impedem misturar suas rodadas. O estado do renderer é separado por
`run_id`, e o fim de um filho não encerra o renderer da sessão.

Eventos de controle sem componente específico são apresentados pelo mesmo
componente genérico de envelope, com tipo, identidade e payload. Não descartá-los
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
Core e manter o estado de múltiplas Runs. Reutilizar seus componentes visuais;
adaptar os consumidores existentes para o contrato único, removendo o caminho de
formatação substituído. Não manter dois renderers equivalentes.

Ligar o `run` a esse caminho comum. O leitor do replay apenas consulta o banco,
sem Runtime, SessionExecutor, interceptores, automações, append, migração ou rebuild
de projeções. Reutilizar a consulta/decodificação existente onde possível e expor
abertura realmente somente leitura no armazenamento. Banco inexistente é erro;
a leitura não cria arquivo nem altera o banco/projeções/inbox.

Para analisar posteriormente uma execução de `run`, oferecer retenção explícita:

```sh
omunculus run ./projeto "instrução" --db ./execucao.sqlite3
omunculus session replay --db ./execucao.sqlite3
```

Nesse modo, criar um banco novo, preservar o log inclusive em falha e informar o
caminho. Recusar destino existente para não misturar sessões. Sem `--db`, manter
a sessão efêmera já definida. Sessões duráveis de `send` continuam usando seu banco.
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
- Redirecionamento captura prompts, respostas, erros e conteúdo extenso completos,
  sem ANSI ou truncamento silencioso. Timestamps e durações vêm do registro.
- `run --db` preserva a sessão e a UI; destino existente é recusado. Replay de
  arquivo inexistente não cria banco. Help e exit codes seguem o contrato acima.

Testes determinísticos com provider fake e captura de IO verificam equivalência,
completude e ausência de efeitos. Um smoke test com provider real gera um banco
novo para revisão manual da UI, sem usar duração como critério de sucesso da tarefa.

## Implementação entregue

`session replay --db` abre SQLite somente leitura, fixa o snapshot e percorre
o log em lotes de 256 envelopes. Usa `CLI.Reporter`, os mesmos componentes de
cabeçalho, rodadas, ferramentas e tabela usados pelo `run`. O detalhe completo
dos envelopes acompanha esses componentes; o estado visual é separado por Run.

O modo ao vivo usa notificações de entrega para ler o prefixo confirmado do log:
isso inclui solicitações rejeitadas que não são entregues aos executores. O fim
da apresentação drena o restante desse prefixo. Campos de conteúdo não são
truncados; a tabela compacta continua sendo um resumo, acompanhado do detalhe.

Os eventos de modelo incluem request, resposta ou falha. O `event_id` do request
é a identidade da chamada, referenciada por `call_id` e `causation_id` no resultado.
Tentativas de ferramentas têm `tool_call_id`, argumentos, resultado, duração e
outcome `completed`, `waiting` ou `error`. A identidade do envelope distingue
tentativas mesmo quando um provider reutiliza IDs. Falhas não registram novos
valores de contador. `control_tools` em `run.started` pina as ferramentas de
permissão/arbitragem para preservar sua autorização ao passarem pelo ToolGate.

`run --db` conserva o banco e recusa arquivo existente. O cliente efêmero retorna
quando a raiz solicita avaliação humana, preservando o registro nesse modo;
a API de espera usada por sessões residentes mantém a espera pela resposta humana.

Históricos anteriores mostram somente os dados realmente registrados. Uma resposta
não capturada aparece como “not recorded”; checkpoints não são convertidos em
eventos retrospectivos. Não houve migração nem implementação de formatos antigos.
