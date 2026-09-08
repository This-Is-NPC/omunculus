# Validação de aprovação parental e etapas opcionais

Critério corrigido e nova execução: [observação sem prazo artificial](no-deadline-validation.md).

Repetição posterior aos ajustes finais: [validação do gate com modelos reais](post-gate-validation.md).

Correção do contrato em 2026-09-07. Referência:
[trabalho, execução e aprovação](../to-be/run-report-and-break.md).

## O que mudou

O relato do executor deixou de concluir antecipadamente o Work Item.
O responsável aprova; o harness conclui ou avança a sequência opcional.
`status` guarda andamento/etapa e `state` guarda execução. Falha técnica
preserva a etapa e chega ao pai, que pode reconhecer efeitos ou orientar
retry. Relatos obsoletos não aprovam uma execução posterior.

Foram removidos os formatos legados de execução, migrações de bancos,
reabertura usada para desfazer conclusão prematura e nudges específicos de
contagem. Providers reais e simulados usam o mesmo protocolo. Os probes
históricos foram substituídos pelos testes do contrato atual e pelo
[script de cenários reais](../../scripts/validate_workflow.exs).

## Testes do harness

A suíte cobre aprovação antes de conclusão, sequência de três etapas,
retries por etapa, raiz com revisão humana configurável, irmãos concorrentes,
falha técnica, reconhecimento sem reexecutar efeitos, escalonamento,
checkpoint, reinício nos intervalos entre decisão/agendamento/ativação,
replay e aprovação obsoleta após outra execução da mesma etapa.

As respostas controladas verificam transições e efeitos observáveis. Não
atestam a qualidade de julgamento de um modelo. A execução isolada de
`mise exec -- mix test` passou com **304 testes, 0 falhas**, seed `389696`,
em 11,8 segundos. Inclui a ativação do reviewer somente na etapa `review`,
preservação do papel do pai nas avaliações e seleção configurável de
modelo, kind e prompt do agente da etapa.

## Amostras reais

Correção metodológica de 2026-09-08: os quatro cortes históricos por tempo
são **interrupções do experimento**, com conclusão da raiz inconclusiva.
Não constituem falha do harness por duração. As observações de efeitos
e decisões são independentes dessa classificação.

Uma execução por cenário e provider, cada qual com banco novo, workspace
em memória, depth máximo 1 e timeout de cliente de 180 segundos. A raiz tem
ferramentas de delegação/descoberta; o filho dispõe de counter. O cenário
com máquina acrescenta implementação e verificação ao fluxo do filho.

O objetivo é produzir exatamente três incrementos, com valores `[1,2,3]`.
O oracle apenas mede os efeitos; não decide aprovações no runtime. Cada
provider executou seus casos sequencialmente. As duas campanhas usaram
processos independentes; houve sobreposição com testes locais, portanto os
tempos não servem para comparação de latência entre providers.

| Provider | Máquina | Valores observados | Avaliações parentais / avanços | Resultado |
| --- | --- | --- | --- | --- |
| Cloud DeepSeek | Desligada | 1,2,3 | 1 / 0 | Filho aprovado; raiz delegou confirmação adicional; timeout |
| Cloud DeepSeek | Ligada | 1…9 | 1 / 0 | Pai reprovou excesso de incrementos; retry continuou incrementando; timeout |
| Local Qwen 9B | Desligada | 1,2,3 repetidos em três Work Items | 3 / 0 | Novas delegações repetiram trabalho; timeout |
| Local Qwen 9B | Ligada | 1…5 | 2 / 1 | Pai aprovou etapa com resultado incorreto; harness iniciou verificação; timeout |

Todas as conclusões/transições observadas tiveram um relato aprovador como
causa; os quatro snapshots foram iguais após replay. Nenhuma raiz concluiu
antes do limite. No caso local com máquina, a flag de aprovação do pai
contradisse seu comentário sobre necessidade de escalonamento. O harness
seguiu a flag explícita; não interpretou o texto como uma decisão diferente.

Essas amostras foram coletadas antes dos últimos ajustes de proteção contra
aprovações obsoletas e da explicitação no prompt de continuação de que os
resultados entregues já foram aprovados. Também antecedem a separação explícita
entre avaliação parental (`assessment`) e papel reviewer na etapa `review`;
os nomes de eventos no JSON preservam essa versão histórica. Os ajustes finais são cobertos por
testes controlados. A campanha posterior está no relatório vinculado no início.

[Evidências sanitizadas](workflow-validation.json) incluem os resultados e
os eventos de avaliação/transição. Não há chaves, cabeçalhos de autenticação
ou configuração de credenciais no artefato.

## Limite da conclusão

O ciclo do harness é testável independentemente do modelo e o avanço por
aprovação foi observado em execução real. Sucesso funcional consistente
com esses providers ainda não foi demonstrado. Quatro amostras exploratórias
não estabelecem uma taxa de confiabilidade, nem permitem atribuir todos os
timeouts exclusivamente ao provider ou ao harness.
