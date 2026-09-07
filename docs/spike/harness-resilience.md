# Diagnóstico de resiliência do harness

Data: 2026-09-07. Baseline de produção: `3bbeeb6`.

**Objetivo corrigido:** medir se o harness conduz e verifica um processo
apesar de respostas imperfeitas do modelo. Os providers são condições de
execução, não o objeto de um ranking. A matriz anterior é exploratória;
seus percentuais não isolam a causa dos insucessos.

## Experimento causal offline

O [probe](../../scripts/probe_harness_resilience.exs) usa Runtime,
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

[Resultados completos](harness-resilience-results.ndjson), oito cenários:

| Perturbação | Comportamento observado | Interpretação |
| --- | --- | --- |
| Nenhuma: cadeia correta | Contador 1..10 em um Work Item; duas continuações; raiz conclui | Caminho básico e entrega do resultado funcionam |
| Raiz responde “10” sem tool | Sucesso para o cliente; zero incrementos | Não há verificação do efeito exigido para concluir |
| Intermediário responde “10” sem tool | Pai continua e conclui; zero incrementos | Uma conclusão sem efeito é propagada |
| Intermediário conta diretamente | Dez incrementos; só depths 0 e 1 | A configuração permite esse atalho; teto de depth não obriga delegação |
| Worker responde “10” por 32 turnos | Cadeia completa e sucesso; zero incrementos | Insistência automática não impede conclusão falsa ao atingir o limite |
| Raiz pede agent sem team, depois corrige | TeamGate rejeita; erro chega ao chat; cadeia correta termina | O harness fornece feedback, mas a correção ainda depende da próxima resposta |
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

Encerrar cada Run ao delegar resolve retenção de processos e permite retomar
o trabalho pelo checkpoint. Não garante que o modelo escolha delegar,
formule uma subtarefa suficiente, execute uma ferramenta, reconheça o erro
ou avalie a entrega do filho. Essas decisões continuam dependendo do modelo
onde não existe um contrato verificável ou uma política do harness.

O plano atual de [execução](../to-be/execution-model.md) considera texto sem
filhos pendentes uma conclusão e prevê retry via `task.resumed`. Portanto,
parte do comportamento observado segue o desenho documentado: falta uma
política de validação e recuperação para sustentar a expectativa de maior
autonomia com modelos limitados. Nem toda lacuna é desvio de implementação.

Há também problemas concretos de implementação já identificados na
[auditoria](methodology-audit.md): instruções do perfil não chegam ao prompt
efetivo e a ajuda para contagem só existe com tools exatamente `[counter]`.
Em [Agent](../../lib/omunculus/agent.ex), o limite não assegura que a meta foi
atingida; em [Runtime.Run](../../lib/omunculus/runtime/run.ex), um resultado
`ok` sem filhos pendentes vira `task.completed` sem validação independente.

**Conclusão causal:** há limitações comprovadas do harness mesmo sem um
modelo real. Uma resposta ruim pode iniciar o problema, mas o harness atual
pode aceitá-la como sucesso ou deixar o fluxo sem resolução. Isso impede
atribuir os resultados anteriores exclusivamente ao modelo. O controle
positivo também impede concluir que a orquestração básica está quebrada.
Este experimento não determina quanto o modelo local conseguirá fazer
depois das correções, nem garante processos arbitrariamente complexos.

## Benchmark do harness a partir desta baseline

1. Definir por cenário o efeito e a evidência de conclusão: sequência e
   valor final do contador no Work Item responsável; arquivo regular com
   conteúdo especificado; resultado do filho consumido até a raiz.
   Distinguir depth máximo de cadeia obrigatória. Separar concierge somente
   com delegação de intermediário autorizado a executar diretamente.
2. Corrigir a entrega das instruções por papel e impedir que texto ou
   esgotamento de turnos seja suficiente para declarar o efeito concluído.
   Não impor uma instrução “only counter” ao concierge que só pode delegar.
3. Definir recuperação limitada e observável: erro recuperável permite
   retry; esgotamento deve encerrar o fluxo com diagnóstico ou solicitar
   intervenção. Considerar idempotência antes de repetir efeitos parciais.
4. Reaplicar perturbações controladas: omissão de tool, argumentos inválidos,
   conclusão falsa, timeout, duplicação, reinício e perda parcial de progresso.
   Os oito casos atuais cobrem apenas parte dessa lista, sem escrita real,
   permissões humanas, concorrência ou recuperação após crash do processo.
5. Repetir os mesmos workflows e contratos com providers reais. Medir
   conclusão verificada, falso sucesso, trabalho sem resolução, recuperação
   sem intervenção, custo de recuperação e tempo separado por camada.

Um modelo menor só estará demonstradamente sustentado pelo harness quando
esses workflows atingirem os critérios e o orçamento definidos. Trocar
apenas o provider antes disso pode ocultar as lacunas, sem corrigi-las.

## Reprodução

```sh
mise exec -- mix run scripts/probe_harness_resilience.exs
```

O script produz observações NDJSON, inclusive comportamentos incorretos da
baseline. Não são testes de regressão que exigem preservar essas falhas.
