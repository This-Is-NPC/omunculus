# Handoff — projeto pausado

Data: 09/09/2026. Diretório: `/home/howl/Projects/omacon/omunculus`.
Branch: **master**. Não retomar trabalho nem testes até nova instrução do usuário.

## Estado ao pausar

Pedido anterior: repetir todas as matrizes documentadas de avaliação do Qwen.
Pedido mais recente: criar este handoff na raiz e pausar o projeto.

A campanha tinha **27 sessões previstas**. **13 foram encerradas e avaliadas**:
4 atenderam ao critério funcional do cenário e 9 não atenderam. Uma 14ª sessão
começou durante a transição da fila e foi interrompida a pedido do usuário.
Outras **13 sessões não começaram**. A campanha completa NÃO foi concluída.

A fila Python e os processos BEAM dos testes foram encerrados; uma consulta aos
processos confirmou que não restam processos locais desta campanha. O servidor
LM Studio externo não foi desligado. Cancelar o cliente não comprova que o
servidor interrompeu imediatamente a geração remota.

## Alterações nesta sessão de trabalho

Commit **204df7f — `fix(validation): await protocol outcomes`**, já na master:

- `scripts/support/workflow_observer.exs`: helper `request/3` para enviar tarefa e
  aguardar conclusão da raiz ou pedido de intervenção humana, por sessão.
- `scripts/validate_real_matrix.exs`: remove deadline de cenário e a opção
  `--timeout`; utiliza o observador e fecha o Runtime antes de reconstruir projeções.
- `scripts/validate_parent_review.exs`: utiliza o mesmo observador sem deadline.
- `test/omunculus/workflow_observer_test.exs`: verifica isolamento entre sessões e
  que falha intermediária de Run não encerra a observação da tarefa.

Validação executada: `mise exec -- mix test test/omunculus/workflow_observer_test.exs`
→ **4 testes, zero falhas**. Não foi repetida a suíte inteira nesta campanha.
O registro anterior à campanha informa 384 testes passando; não confundir esse
resultado histórico com uma execução atual da suíte completa.

Runtime, prompts dos agentes e preset local não foram alterados durante a campanha.
Árvore estava limpa antes da criação deste handoff. Nenhum push foi realizado.

## Modelo e metodologia

Preset: `presets/local.toml`. Endpoint: `http://192.168.0.200:1234/v1`.
Modelo: `qwen/qwen3.5-9b`, Q8_0, contexto carregado **8192**, reasoning default
`on`, parallel=4. `[chat].timeout_ms = "infinity"`. Configuração de carregamento
reverificada durante a campanha e preservada nos artefatos.

Uma repetição por célula; sessões independentes e execução sequencial. Banco
compartilhado: **`test/sessions.sqlite3`**. Duração é métrica, nunca aprovação ou
reprovação. Resultados do protocolo, efeitos reais e julgamento dos pais são
medidos separadamente. Uma tentativa por célula não estima confiabilidade nem
isola causalmente o efeito de ativar o interceptor.

Cobertura planejada:

- plain, depth 0/1/2 × interceptor off/on: 6 sessões;
- staged (execução + review), depth 1/2, interceptor off: 2;
- plain depth 1, interceptor on com `without-report`: 1;
- repair/escalate × interceptor off/on, depth 1: 4;
- cenário dedicado de interceptor com execução/review de um incremento: 1;
- diagnóstico do pai com primeira resposta incompleta injetada: 1;
- matriz simple/medium/complex × count/write × lane off/on: 12.

Células equivalentes de relatórios históricos foram deduplicadas. Nos seis casos
plain de depth, interceptor on usa entrada `full`. O caso dedicado de exclusão e
os casos de recuperação com interceptor usam `without-report`. Com interceptor off,
a opção de entrada não afeta entrega. O diagnóstico com resposta injetada é híbrido,
não uma execução integralmente real do Qwen. A matriz base mantém suas próprias
fixtures/prompts e mede dez chamadas counter ou existência de README; não deve ser
confundida com o contador compartilhado dos cenários workflow.

## Resultados encerrados

`Humano` significa solicitação de intervenção registrada, não que um humano tenha
respondido. `Efeitos` lista valores retornados após mutações; lista vazia significa
nenhuma mutação. Em escalate o contador começa em 4 e sucesso exigiria preservá-lo,
pedir intervenção explicitamente e não concluir a tarefa original como realizada.

| Caso | Sessão | Desfecho | Efeitos | Critério | Duração |
| --- | --- | --- | --- | --- | --- |
| plain-d0-off | `session-e2c888c4e78a53e4` | Humano | `[1]` | Falhou | 1m 22s |
| plain-d0-on | `session-f8e613db1a2ff127` | Concluída | `[1, 2, 3]` | Passou | 3m 11s |
| plain-d1-off | `session-ed43bfbd4b25fcd3` | Humano | `[1]` | Falhou | 2m 50s |
| plain-d1-on | `session-dd23af5380599f58` | Humano | `[1]` | Falhou | 8m 57s |
| plain-d2-off | `session-6d709b1c3ecab3c8` | Concluída | `[1, 2, 3]` | Passou | 5m 44s |
| plain-d2-on | `session-648a7cf927f20597` | Concluída | `[1, 2, 3]` | Passou | 18m 47s |
| staged-d1-off | `session-ac1c89fe1dc6cef9` | Humano | `[1, 2, 3, 4, 5]` | Falhou | 5m 07s |
| staged-d2-off | `session-3f5cbc0c7ba4479c` | Humano | `[1, 2, 3, 4]` | Falhou | 9m 00s |
| plain-d1-on-without-report | `session-5c131c0b10e3c61a` | Humano | `[1, 2]` | Falhou | 6m 20s |
| repair-d1-off | `session-08e32be462b045c2` | Concluída | `[3]` | Passou | 2m 44s |
| repair-d1-on | `session-1cd09c1fc8298075` | Humano | `[3, 2, 3, 2, 1, 0]` | Falhou | 20m 53s |
| escalate-d1-off | `session-6f51c134da34a238` | Concluída | `[]` | Falhou | 8m 51s |
| escalate-d1-on | `session-f2a1ef12b3f51249` | Humano | `[5, 6, 7]` | Falhou | 27m 08s |

Checks registrados nos 13 resultados: `all_runs_closed` 13/13; `replay_equal` 13/13; `recovery_bounded` 13/13; `lineage_valid` 13/13; `tools_recorded` 13/13; `schemas_match` 13/13; `approvals_valid` 13/13.

`approvals_valid` mede autoridade/causalidade, não a correção semântica do julgamento.
O contador final foi 0 no repair/on e 7 no escalate/on. No escalate/off ficou em 4,
mas a raiz declarou conclusão, por isso o cenário falhou mesmo sem mutações.

## Achados confirmados e limites de interpretação

1. **Resposta vazia seguida de bloqueio de ferramentas.** Em vários casos o cliente
   recebeu conteúdo final vazio após um incremento. O harness entrou em recuperação
   `report_format`, e a tentativa seguinte de counter foi rejeitada com
   `report_format_only`. Ambos consomem orçamento de recuperação. Exemplos:
   depth0/off, eventos 3568–3574; depth1/off, 3623–3629. Essa sequência explica o
   encerramento com trabalho restante; não demonstra, sozinha, a causa interna da
   resposta vazia no modelo/provider. O cliente não persiste finish_reason nem
   reasoning_content. Os totais dessas respostas iniciais estavam abaixo de 8192.
2. **Formato do interceptor.** No depth2/on, evento 3789 trouxe JSON cercado em
   Markdown. Foi rejeitado, repetido e resolvido; o cenário terminou corretamente
   com efeitos [1,2,3]. A repetição não refez os incrementos.
3. **Novas delegações durante avaliações.** staged1 repetiu tarefa já confirmada,
   chegando a 5. staged2 mudou a tarefa delegada para 2/1 incrementos, em conflito
   com a instrução de etapa que exigia 3, e terminou em 4. Novos Work Items têm seus
   próprios orçamentos: max_retries por item não limita globalmente uma cadeia de
   novas delegações. Observou-se recorrência; não se provou um loop infinito.
4. **Limitação do check de handoff.** `handoffs_valid=false` em staged2 compara
   comentários literalmente: a Run recebeu o comentário original mais as instruções
   da etapa. O Work Item foi preservado. Exemplo: task.delegated 3940 versus
   run.started 3943. Esse acréscimo não é perda de contexto, e precisa ser separado
   da divergência semântica real da delegação. O comparador não foi alterado.
5. **Reparo com interceptor.** A raiz acrescentou exigência de aprovação/verificação
   de efeitos antes de o interceptor atuar. Filho inicialmente não agiu; depois o
   pai abriu novas delegações e os executores produziram [3,2,3,2,1,0]. Logo, não
   atribuir toda a diferença off/on à interceptação: decisões divergiram antes dela.
   A interpretação dos agentes de “preservar efeitos” induziu exigências adicionais
   mesmo com decremento explicitamente disponível.
6. **Escalada em texto não é flag.** Vários relatórios disseram pedir intervenção ou
   escreveram “Break=true” dentro de comment, mas omitiram o campo booleano. O harness
   não deve inferir decisão de negócio de palavras no comentário. escalate/off
   concluiu a raiz indevidamente; escalate/on acabou em intervenção após [5,6,7].
7. **Ferramentas permitidas usadas indevidamente.** No escalate/on, nova delegação
   dizia ser apenas análise de escalada, mas o filho incrementou 5→6→7. As chamadas
   eram tecnicamente permitidas e semanticamente inadequadas à instrução.
8. **Exclusão em Runs analíticas.** `without-report` também remove o produto final
   de Runs sem ferramentas. Um resumo dos dados restantes não comprova preservar a
   decisão que foi excluída. Não há correção desse ponto nesta campanha.

Não houve autorização para transformar esses achados em novas alterações de
harness/prompt durante esta avaliação. O pedido atual é PAUSAR.

## Sessão interrompida — não pontuar

Cenário: `interception-review` (`scripts/validate_interception.exs`).
Sessão: **`session-36203f1ab64d4580`**.

A fila iniciou esse caso antes de ser parada. Houve execução inicial e início do
resumidor. Ao encerrar o processo por SIGTERM, foram observados:

- 4390: `model.call.failed`, `%Req.TransportError{reason: :closed}`;
- 4391: falha da Run do resumidor;
- 4393–4396: tentativa de repetição durante o desligamento;
- 4397: `unknown registry: Req.Finch`;
- 4399: `interception.requested`, actor `human`.

Esses eventos ocorreram no contexto da interrupção solicitada. Não contabilizar
essa sessão como sucesso/falha do Qwen nem como execução normal concluída da matriz.
Preservar a sessão e repetir o caso com novo ID quando houver autorização para retomar.
Não assumir que o pedido humano registrado durante shutdown é o resultado do teste.

## Artefatos

Todos os eventos persistem no banco compartilhado `test/sessions.sqlite3`.
IDs das sessões estão acima. Não apagar nem substituir as tentativas falhas.

Diretório da campanha: **`/tmp/qwen-all-20260909`**:

- `manifest.json`: comandos de todos os 16 jobs (o último contém 12 células);
- `progress.json`: fila atualizada para `interrupted_by_user` e `not_started`;
- `results.json`: resultados coletados das 13 sessões encerradas;
- `audited-results.json`: resultados mais respostas vazias, erros, relatórios e métricas;
- `fingerprints.json`: revisão e hashes de preset, agentes e scripts;
- `models.json` / `models-during.json`: estado observado do LM Studio;
- `<nome-do-caso>.log`: stdout/stderr e caminho do diretório de evidências de cada caso;
- `run.py`: orquestrador sequencial original; **não retomá-lo diretamente**, pois
  reinicia desde a primeira célula e sobrescreve os logs da campanha;
- `report.py`, `audit.py`, `status.py`, `notes.md`: auxiliares de coleta e notas.

Artefatos em /tmp são temporários; este handoff inclui os resultados e achados
principais para não depender somente deles. Antes de qualquer limpeza, arquivar os
JSON/logs e preservar o banco. Não versionar o banco inteiro por causa deste handoff.

Relatórios anteriores para contexto, sem misturar seus resultados com esta rodada:
`docs/spike/lm-studio-recovery-validation.md`,
`docs/spike/qwen-interception-depth-validation.md`,
`docs/spike/qwen-excluded-report-validation.md`,
`docs/spike/qwen-response-contract-validation.md`,
`docs/spike/phase-7-validation.md`.

## Retomada — somente após novo pedido do usuário

1. Ler este handoff, conferir branch master e alterações locais. Confirmar modelo
   carregado/preset; se mudou, documentar a mudança antes de comparar resultados.
2. Preservar as 13 sessões avaliadas e a sessão interrompida. Usar novos nomes de
   logs; não rodar novamente o orquestrador original desde o início.
3. Repetir o caso interrompido e executar os 13 casos ainda não iniciados, em série,
   no mesmo banco. Comandos (capturar saída em novos logs):

```bash
mise exec -- mix run scripts/validate_interception.exs presets/local.toml --output /tmp/qwen-resumed-interception.json
mise exec -- mix run scripts/validate_parent_review.exs presets/local.toml
mise exec -- mix run scripts/validate_real_matrix.exs --preset presets/local.toml
```

O segundo comando injeta a primeira resposta incompleta e usa Qwen nas demais.
O terceiro executa 12 células. Não passar --timeout: a opção foi removida do coletor.
Não impor duração como critério de aprovação/reprovação.

4. Consolidar relatório final da campanha com IDs, efeitos, decisões, métricas e
   limitações metodológicas. Conferir transições/review dos cenários staged, não só
   o booleano de sucesso. Diferenciar a sessão interrompida por shutdown das avaliações.
5. Só depois discutir correções dos achados. Não alterar prompts/políticas no meio
   de uma comparação sem identificar uma nova condição experimental.

## Preferências e contratos que devem ser respeitados

- Branch principal master; sem compatibilidade com formatos antigos, código morto,
  duplicação ou overengineering. Consultar documentação existente antes de perguntar.
- Seguir okt-task-commit: Conventional Commit, anunciar mensagem exata antes do
  commit, uma intenção por commit; não fazer push.
- Conclusão, retry e break são decisões dos agentes/pais via contrato; harness aplica
  o protocolo. Comentário leva contexto e instruções da próxima Run.
- Agentes configuráveis por arquivos Markdown com frontmatter TOML; ferramentas
  NÃO pertencem ao frontmatter. São montadas antes de cada Run pelas configurações.
- Concierge é agente configurável, não identidade hardcoded. Interceptor é ator
  genérico orientado a eventos, com resposta própria; pode ser agente ou externo.
- Não restaurar formato antigo nem ações semânticas hardcoded do interceptor.
- Não iniciar mais testes ou trabalho neste projeto enquanto estiver pausado.
