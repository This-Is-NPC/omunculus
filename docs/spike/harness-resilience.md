# Diagnóstico de resiliência do harness

Data: 2026-09-07. Baseline de produção: `3bbeeb6`.

**Objetivo corrigido:** medir se o harness oferece contexto e mecanismos
para os agentes conduzirem e avaliarem um processo apesar de respostas
imperfeitas. O pai julga a entrega do filho; o runtime mantém os contratos
de execução. Os providers são condições de
execução, não o objeto de um ranking. A matriz anterior é exploratória;
seus percentuais não isolam a causa dos insucessos.

## Experimento causal offline

O probe histórico (preservado no histórico Git) usa Runtime,
EventCore, Projector, TeamGate e o resolver de agentes de produção com
`complex.toml` + `lane.toml`. Substitui apenas as respostas do chat por
respostas controladas; usa filesystem em memória e bancos isolados.
Não usa o resolver alternativo de scripts nem chama um provider real.

A tarefa é contar até 10 usando a ferramenta. A cadeia de controle percorre
0 → 1 → 2. Cada cenário altera uma resposta ou uma intervenção. O controle
positivo só permite aos pais responder depois de encontrar o resultado do
filho no contexto restaurado. No cenário de falha, não há efeitos antes do
erro; portanto, a recuperação não demonstra segurança contra efeitos
duplicados após falhas parciais.

[Resultados completos](harness-resilience-results.ndjson), nove cenários:

| Perturbação | Comportamento observado | Interpretação |
| --- | --- | --- |
| Nenhuma: cadeia correta | Contador 1..10 em um Work Item; duas continuações; raiz conclui | Caminho básico e entrega do resultado funcionam |
| Raiz responde “10” sem tool | Sucesso para o cliente; zero incrementos | O agente declara uma conclusão incorreta; o runtime segue o contrato de texto final |
| Intermediário responde “10” sem tool | Pai continua e conclui; zero incrementos | O pai simulado aceita o resultado; esse teste não exercita revisão |
| Intermediário conta diretamente | Dez incrementos; só depths 0 e 1 | A configuração permite esse atalho; teto de depth não obriga delegação |
| Worker responde “10” por 32 turnos | Cadeia completa e sucesso; zero incrementos | Insistência automática não impede conclusão falsa ao atingir o limite |
| Raiz pede agent sem team, depois corrige | TeamGate rejeita; erro chega ao chat; cadeia correta termina | O harness fornece feedback, mas a correção ainda depende da próxima resposta |
| Filho informa entrega incompleta; pai pede correção | Pai delega novamente; nova cadeia conta 1..10; três continuações | O mecanismo de revisão e nova delegação pelo pai funciona |
| Filho retorna erro simulado | Filho failed; dois pais waiting; cliente expira | Falha não produz recuperação automática nem erro terminal na raiz |
| Mesmo erro seguido de task.resumed | Uma retry Run e duas continuações; contador 1..10 | O mecanismo de recuperação existe; o comando veio do probe |

No controle positivo, o probe pausa o worker e verifica que **somente a Run
de depth 2 está ativa**. As duas Runs dos pais já registraram conclusão
`waiting`. Após o erro do filho, verifica **zero Runs ativas**, um Work Item
`failed` e dois `waiting`. São dependências lógicas persistidas, não processos
dos pais bloqueados esperando a execução do filho.

`client_success` significa o retorno atual do Runtime, não o veredito de
correção do benchmark. `provider_calls` conta eventos de chamadas concluídas
ao chat simulado; não inclui a chamada que retorna erro. O timeout de dois
segundos é um limite de observação offline, não uma medida de latência real.

## Por que o isolamento das Runs não basta

**Retificação da interpretação inicial:** os pais dos casos de conclusão
falsa foram programados para devolver “10” quando recebessem “10”. Isso
mostra a propagação de uma avaliação ruim, não prova que falta ao harness
um mecanismo para o pai revisar. No novo cenário, o pai identifica a entrega
incompleta e usa `delegate` outra vez. A revisão é uma resposta controlada,
não uma demonstração de julgamento de um modelo real.

Encerrar cada Run ao delegar resolve retenção de processos e permite retomar
o trabalho pelo checkpoint. Não garante que o modelo escolha delegar,
formule uma subtarefa suficiente, execute uma ferramenta, reconheça o erro
ou avalie a entrega do filho. Essas decisões pertencem aos agentes. O harness
precisa entregar o contexto, os prompts e as ferramentas que lhes permitem
exercer essa responsabilidade; não substituir julgamento semântico por uma
regra universal de aceitação.

O plano atual de [execução](../to-be/execution-model.md) considera texto sem
filhos pendentes uma conclusão e prevê retry via `task.resumed`. Portanto,
parte do comportamento observado segue o desenho documentado. `task.completed`
do filho registra a entrega dele, não a aprovação pelo pai. Na continuação,
o pai pode pedir novamente ou concluir seu próprio Work Item. Não há, no
catálogo atual, uma tool separada `accept`/`reject` para aprovar entregas.
O mecanismo documentado é a continuação com nova decisão do agente.

Há também problemas concretos de implementação já identificados na
[auditoria](methodology-audit.md): instruções do perfil não chegam ao prompt
efetivo e a ajuda para contagem só existe com tools exatamente `[counter]`.
Em [Agent](../../lib/omunculus/agent.ex), o limite não assegura que a meta foi
atingida; em [Runtime.Run](../../lib/omunculus/runtime/run.ex), um resultado
`ok` sem filhos pendentes vira `task.completed` sem validação independente.

**Conclusão causal revisada:** o transporte da entrega, a retomada do pai e
a possibilidade de pedir correção funcionam nos cenários controlados.
Os prompts das fixtures mandam o concierge repetir o resultado recebido;
não instruem avaliação nem pedido de correção. Essa lacuna, somada às
instruções do perfil não propagadas, impede atribuir os resultados anteriores
exclusivamente ao modelo. Os testes de texto falso não justificam transferir
a aprovação semântica para o runtime. A falha técnica do filho sem retomada
permanece uma observação separada; não foi corrigida pelo novo cenário.
Este experimento não determina quanto o modelo local conseguirá fazer
depois das correções, nem garante processos arbitrariamente complexos.

## Benchmark do harness a partir desta baseline

1. Definir por cenário o efeito e a evidência de conclusão: sequência e
   valor final do contador no Work Item responsável; arquivo regular com
   conteúdo especificado; resultado do filho consumido até a raiz.
   Distinguir depth máximo de cadeia obrigatória. Separar concierge somente
   com delegação de intermediário autorizado a executar diretamente.
2. Corrigir a entrega das instruções por papel. O pai deve definir a tarefa,
   avaliar a entrega e pedir correção quando necessário; o filho deve relatar
   resultado, evidências, limitações e pendências. Isso é um contrato de
   comunicação, não um verificador universal de qualidade. Não impor uma
   instrução “only counter” ao concierge que só pode delegar.
3. Distinguir o protocolo de revisão de uma entrega das falhas técnicas sem
   entrega. Avaliar como expor estas ao decisor conforme o plano, preservando
   `task.resumed` e a decisão antes de repetir efeitos desconhecidos. Limites
   de turnos devem permanecer observáveis sem equivaler a qualidade aprovada.
4. Reaplicar perturbações controladas: omissão de tool, argumentos inválidos,
   conclusão falsa, timeout, duplicação, reinício e perda parcial de progresso.
   Os nove casos atuais cobrem apenas parte dessa lista, sem escrita real,
   permissões humanas, concorrência ou recuperação após crash do processo.
5. Repetir os mesmos workflows e contratos com providers reais. Medir
   conclusão verificada, falso sucesso, trabalho sem resolução, recuperação
   sem intervenção, custo de recuperação e tempo separado por camada.

Um modelo menor só estará demonstradamente sustentado pelo harness quando
esses workflows atingirem os critérios e o orçamento definidos. Trocar
apenas o provider antes disso pode ocultar as lacunas, sem corrigi-las.

## Reprodução

O probe preserva explicitamente `workflow: false` para reproduzir a baseline
v1. O contrato novo é validado por `workflow_test.exs`, não por este probe.

```sh
# Probe de protocolo antigo removido; use os testes do contrato atual.
```

O script produz observações NDJSON, inclusive comportamentos incorretos da
baseline. Não são testes de regressão que exigem preservar essas falhas.

## System prompts e outputs esperados

Atualização: o protocolo e as fixtures foram corrigidos após este diagnóstico;
veja [validação dos prompts](parent-review-validation.md). A descrição abaixo
registra o estado anterior, não o comportamento da composição atual.

As fixtures medium e complex dizem ao concierge para delegar e responder
somente com o resultado devolvido. O worker deve responder somente com o
resultado. Não há instrução para explicitar evidências, avaliar suficiência,
pedir retrabalho ou distinguir entrega parcial de conclusão satisfatória.
O fallback do resolver também é genérico. O checkpoint preserva essas
mensagens na continuação; o texto de retorno é `Sub-agent completed. Result:
... Still pending: ...`, sem orientação adicional de revisão.

Uma composição coerente deve explicar o protocolo comum, o papel configurado,
o contexto da Run e as instruções da tarefa compatíveis com suas tools.
Critérios semânticos ficam na instrução delegada e no julgamento do pai.
Um concierge sem filesystem pode pedir evidências ou delegar uma verificação;
não deve receber uma obrigação de inspecionar usando ferramentas ausentes.

O próximo experimento real deve comparar os mesmos cenários antes/depois
dessa composição, incluindo filho que entrega algo incompleto e pai que
pede correção. Os verificadores externos do benchmark medem o resultado;
eles não se tornam gates de execução. Ainda não está demonstrado que mudar
os prompts, sozinho, resolve os insucessos do modelo local.
