# Validação real após a separação do gate de review

Executada em 2026-09-07 sobre o commit `56e9640`, sem alterações no runtime,
nos presets ou nos prompts durante a campanha. **Nenhuma das quatro raízes
concluiu dentro de 180 segundos.** O gate iniciou no papel correto nos dois
providers; isso não garantiu preservação dos efeitos nem aprovação correta.

## Método e reprodução

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/cloud.toml
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml
```

Os comandos foram executados sequencialmente, assim como os dois casos de
cada comando. Cada caso teve banco novo, workspace em memória e depth máximo
1. O concierge dispõe de delegação/descoberta; o perfil `count` permite
`counter` e delegação. O fluxo opcional do worker é `in_progress` → `review`,
com `agent = "reviewer"` na segunda etapa. Uma repetição por combinação.

O critério externo de efeito é exatamente três chamadas, retornando
`[1,2,3]` no conjunto da tarefa, sem novas chamadas durante revisão ou
continuação. O contador é mantido por Work Item: `[1,2,3,1,2,3]` significa
trabalho repetido em dois filhos. Sucesso completo exige também conclusão
da raiz. O oracle não decide a aprovação no harness.

O script encerra o runtime ao terminar a espera de 180 segundos. Assim,
`timeout` é um corte do experimento, não evidência de deadlock, de falha
registrada ou de que a tarefa jamais concluiria com mais tempo. As quatro
últimas Runs ficaram sem evento terminal nesse corte. Não foram retomadas.
Não houve outra campanha ou suíte de testes lançada por este agente em
paralelo; a carga externa do host e dos providers não foi controlada.

## Resultados por cenário

| Provider | Fluxo do filho | Valores produzidos | Runs / avaliações do pai / gates | Ponto do corte |
| --- | --- | --- | --- | --- |
| DeepSeek cloud | Desligado | 1,2,3,1,2,3 | 6 / 2 / 0 | Pai avaliando segundo filho, criado para repetir verificação |
| DeepSeek cloud | Com review | 1,2,3 | 5 / 2 / 1 | Pai avaliando o gate já entregue; filho ainda não concluído |
| Qwen local 9B | Desligado | 1,2,3,4,5 | 6 / 2 / 0 | Segundo retry do worker após reprovação |
| Qwen local 9B | Com review | 1,2,3,4,5,6 | 6 / 2 / 1 | Filho aprovado com resultado incorreto; raiz em continuação |

Modelos: `deepseek/deepseek-v4-flash-0731` e `qwen3.5:9b`.
Tempos observados: 180,028 s; 180,013 s; 180,205 s; 180,020 s,
respectivamente. Houve 11, 8, 13 e 13 chamadas de modelo concluídas.
Esses tempos medem principalmente o limite imposto, não o tempo natural
para concluir; não sustentam ranking de desempenho.

Os quatro replays reproduziram seus snapshots. Os quatro eventos de
aprovação/avanço observados tiveram `completed=true` do responsável como
causa. No local sem fluxo não houve tais eventos: `approvals_valid=true`
nesse caso é uma checagem vazia, não evidência de aprovação correta.
Nenhum `run.failed` ou `task.break` foi registrado antes do corte. Houve
uma chamada com nome de ferramenta vazio, negada, no local com fluxo;
a métrica `failures` do script conta falhas de Run e não captura esse erro.

## O que as evidências explicam

### Correção do formato pode repetir trabalho já feito

No local sem fluxo, a Run do worker chegou a 3 e relatou corretamente a
conclusão em texto. O harness rejeitou o formato e pediu JSON. O modelo
chamou `counter`, chegando a 4. Depois de outra resposta textual rejeitada,
chamou novamente, chegando a 5. Tudo ocorreu na mesma Run, antes da primeira
avaliação do pai: não foram retries autorizados pelo pai.

O checkpoint do evento 27 preserva essa sequência. O pedido estrutural de
correção em `lib/omunculus/agent.ex` mantém o ciclo de ferramentas ativo.
O modelo escolheu chamadas indevidas; o harness permitiu que a reparação
do relato voltasse a produzir efeitos. Este é um caminho concreto a testar
e corrigir, sem tornar o julgamento da tarefa determinístico.

O cloud também teve custo de formato: o reviewer produziu texto e JSON em
Markdown, repetiu esse formato após correção e só entregou JSON puro na
terceira resposta. Foram aproximadamente 55,8 segundos nessa Run. O prompt
diz “End with a JSON object”, enquanto o parser exige a resposta inteira
em JSON. Essa diferença é uma possível contribuição do contrato de prompt,
não uma causa isolada demonstrada por comparação controlada.

### Papel reviewer não restringiu ferramentas da etapa

Ambos os fluxos avançaram por aprovação do pai e iniciaram uma Run com
`agent_kind=reviewer`, `stage=review`, `reason=step`. As avaliações do pai
mantiveram `agent_kind=concierge`.

No cloud, o reviewer não fez novos incrementos. No local, executou três,
produzindo 4, 5 e 6. O prompt proibia incrementar novamente, mas `counter`
continuava disponível pela política herdada. A configuração de agente da
etapa muda papel/prompt/modelo; ela não cria uma restrição de ferramentas.
Portanto, o teste confirmou seleção de papel, mas expôs a insuficiência da
restrição apenas textual para este gate sem efeitos.

O reviewer local declarou `completed=true`, alegando que desvios posteriores
não anulavam o resultado anterior. O pai recebeu o checkpoint com valor 6
e mesmo assim aprovou citando `[1,2,3]`. O harness aplicou a decisão explícita.
O oracle externo identificou a aprovação incorreta; não cabe ao runtime
substituir esse julgamento por uma interpretação automática de qualidade.

### A continuação ainda pode repetir uma entrega aprovada

No cloud sem fluxo, o pai aprovou o primeiro filho, mas em sua continuação
delegou outra verificação. A nova instrução autorizava refazer os incrementos
se o novo filho não tivesse observado os valores pessoalmente. O segundo
filho repetiu `[1,2,3]`.

O checkpoint do evento 29 confirma que o prompt atualizado de continuação
estava presente: dizia que resultados entregues já estavam aprovados e que
não se deveria repetir efeitos. A repetição não foi causada pela ausência
dessa camada. A combinação de instruções de coordenação e exigência de
observação ainda precisa de uma comparação controlada de contexto.

### Escalonamento textual não equivale à flag

No local sem fluxo, o pai reprovou o excesso e escreveu que queria escalar,
mas não emitiu `break=true`. O harness agendou retry segundo `completed=false`.
Não houve break antes do corte. Isso demonstra dificuldade de expressar a
decisão no protocolo, não prova ausência do mecanismo de break.

Nesse caso o modelo também escolheu o nome não configurado `worker_counter`,
aceito pelo resolver como worker. Não desviou um fluxo neste caso sem
máquina, mas é outra fronteira estrutural a cobrir: seleção de agente
inexistente não deveria passar despercebida em uma campanha de papéis.

## Conclusão e próximos controles

Os mecanismos de aprovação, avanço, seleção do reviewer e replay funcionaram
nos eventos observados. A confiabilidade de ponta a ponta continua não
demonstrada. As falhas incluem decisões do modelo e condições oferecidas
pelo harness; trocar somente o modelo não está justificado por esta amostra.

Os próximos controles devem reproduzir a correção de formato que volta a
executar ferramentas e a disponibilidade de ferramenta mutável no gate.
Depois, repetir com a restrição de ferramentas definida na configuração
da etapa, mantendo a aprovação semântica com o pai. Separar o orçamento de
encerramento das métricas de efeitos permitirá observar a conclusão natural
sem confundir latência com repetição ou aprovação incorreta. Essas mudanças
não foram implementadas nesta campanha.

[Evidências sanitizadas](post-gate-validation.json) incluem resultados,
sequências de eventos, estados no corte e checkpoints selecionados com os
prompts e respostas que sustentam os achados. As amostras anteriores foram
preservadas em [workflow-validation.md](workflow-validation.md).
