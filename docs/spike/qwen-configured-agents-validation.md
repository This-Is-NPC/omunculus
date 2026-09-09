# Qwen após remoção das camadas de topologia

Harness `5417e36`, modelo `qwen3.5:9b`, `presets/local.toml`. Quatro sessões
independentes, uma por cenário, executadas sequencialmente no mesmo servidor local.
Configuração de agentes vem de `test/fixtures/config/medium.toml`: os prompts de
concierge e worker desse arquivo substituem os padrões. Código e configuração
não foram alterados durante a campanha. Duração não decide sucesso ou fracasso:
a observação termina na conclusão da raiz ou solicitação de intervenção humana.

## Resultado

| Cenário | Desfecho | Efeitos registrados | Runs / respostas | Recuperações | Duração |
|---|---|---|---:|---:|---:|
| Depth 1, sem workflow | Aguarda humano | `[1,2,3,4,5,1,2,3]`, dois Work Items | 5 / 14 | 2 | 4m12s |
| Depth 1, implementação/review | Concluído, efeitos corretos | `[1,2,3]` | 6 / 12 | 3 | 2m57s |
| Depth 2, sem workflow | Aguarda humano | `[1,2,3,4,5]`, mesmo Work Item | 7 / 13 | 2 | 4m14s |
| Depth 2, implementação/review | Aguarda humano, sem executor | Nenhum | 1 / 3 | 2 | 2m59s |

As 19 Runs fecharam. As 42 respostas não produziram evento `run.failed`.
O orçamento foi respeitado por Work Item/etapa, e as quatro reconstruções das
projeções foram idênticas. Os três casos pendentes não tiveram aprovação de
conclusão. O caso concluído passou pela etapa de review e por três aprovações.

**Uma conclusão com efeitos corretos não significa conformidade integral:** nesse
caso, as três chamadas de counter continham argumentos proibidos pelo schema.
Nenhum dos quatro cenários demonstrou simultaneamente conclusão correta e uso
integralmente conforme das ferramentas.

A campanha anterior teve 3/4 conclusões com efeitos corretos; esta teve 1/4.
Uma repetição por cenário, sem controle de seed e sem isolar cada mudança, não
estima confiabilidade nem prova regressão causada pelo prompt. A simplificação
não demonstrou resolver os problemas do conjunto modelo/harness.

## Evidências e causas

1. **Argumentos não validados pelo harness.** O schema de `counter` declara
   `properties={}` e `additionalProperties=false`. Apesar disso, oito das dezesseis
   chamadas com efeito aceitaram `amount` ou `team`. O modelo inventou os campos;
   o harness permitiu executá-los. Exemplos: eventos 2131/2132 (`amount=1`),
   2135/2136 (`amount` contendo prosa e número absurdo), 2213/2214
   (`team=default`). `Tools.Counter.call/2` ignora args e incrementa o estado;
   o caminho de execução não rejeita esses campos conforme o schema exposto.
   Esse defeito é estrutural, independente da decisão semântica do pai.
2. **Parada e correção inadequadas.** No depth 1 sem workflow, a instrução recebida
   dizia exatamente três chamadas; o executor fez cinco. Reconheceu o excesso
   (2154). O pai delegou correção a um novo Work Item (2162), que iniciou outro
   contador e produziu 1/2/3, sem desfazer os efeitos anteriores. A tentativa
   seguinte foi bloqueada pelo orçamento (2187), terminando em break humano.
3. **Tarefa distorcida antes da execução.** No depth 2 sem workflow, raiz e
   intermediário delegaram revisão de uma suposta execução anterior (2270/2277),
   antes de existir evidência. O executor usou argumentos válidos `{}`, mas fez
   quatro incrementos. O pai rejeitou; a correção no mesmo Work Item gerou o
   quinto incremento. Houve break explícito e escalonamento. Aqui o problema não
   depende dos argumentos extras do counter.
4. **Handoff malformado corretamente rejeitado.** No depth 2 com review, a raiz
   inventou efeitos já concluídos, time e níveis. Enviou `instruction` separado
   e `work_item` como string com fragmentos de markup (2346). Três tentativas
   foram rejeitadas como `invalid_work_item_handoff` (2347/2352/2357), com duas
   recuperações e depois intervenção humana. Nenhum filho ou gate de review
   começou; isso não demonstra falha causada pelo gate.
5. **Contexto e julgamento ainda precisam ser avaliados.** O pai no cenário
   concluído recebeu o checkpoint do executor com calls/value=3; não houve
   repetição dos efeitos na etapa review. Isso não resolve a limitação já
   documentada de evidências estruturadas de descendentes não chegarem ao avô.
   As decisões dos pais continuam sendo do modelo, não do oráculo do teste.

Os system prompts registrados não contêm as antigas camadas `Depth:`, `Kind:`
ou `Run reason:`. Mesmo assim, o modelo inventou níveis nos próprios outputs.
A tarefa do teste ainda exige uma cadeia de delegação no Work Item: retirar
metadados do system prompt não remove esse requisito da tarefa.

## Limitação identificada na medição

`handoffs_valid=false` no caso depth 1 com review decorre da comparação de comment
literal pelo auditor. O início da Run agora acrescenta a instrução configurada da
etapa. O Work Item permanece idêntico e o comment original é preservado, seguido
exatamente dessa instrução. O artefato conserva a flag original e a comparação
explícita `comment_matches_with_configured_stage`; não se alterou o auditor nem o
runtime para melhorar o resultado durante a campanha. `approvals_valid=true`
verifica causalidade, não veracidade do julgamento; nos casos sem aprovações,
essa checagem é vazia. `schemas_match` compara nomes das tools, não seus argumentos.

## Próximo passo sustentado pelos dados

Validar argumentos contra o schema efetivamente exposto **antes de executar** a
ferramenta, usando o mesmo caminho de erro/recuperação já existente. Isso não
transforma avaliação de conclusão em regra determinística: apenas faz cumprir o
contrato estrutural. Depois repetir os cenários e avaliar separadamente os erros
de interpretação, preservação da tarefa, parada e correção do Qwen. Não há base
para atribuir tudo ao modelo nem para declarar o harness validado pelo contador.

## Sessões e reprodução

Banco: `test/sessions.sqlite3`.

| Cenário | Session ID |
|---|---|
| Depth 1 sem workflow | `session-75109e315cfe8fd5` |
| Depth 1 com review | `session-dce6433cdcc44298` |
| Depth 2 sem workflow | `session-a4c987bbbdc7f1be` |
| Depth 2 com review | `session-775d470cfa72a80b` |

```sh
./omunculus session replay session-75109e315cfe8fd5 --db test/sessions.sqlite3 --ui narrative
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml --depth 1 --repeats 1
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml --depth 2 --repeats 1
```

[Artefato auditável](qwen-configured-agents-validation.json): resultados originais,
prompts/schemas enviados, efeitos, argumentos inválidos, reports, recuperações e
handoffs com IDs e sequências. [Campanha anterior](local-handoff-validation.md).
Nenhuma sessão desta campanha continua executando; três aguardam decisão humana.
