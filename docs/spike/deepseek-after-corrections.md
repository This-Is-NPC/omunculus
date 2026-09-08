# Reavaliação DeepSeek após as correções

Execução sobre `32eaac7`, com `deepseek/deepseek-v4-flash-0731` pelo preset
cloud. **Os dois cenários concluíram corretamente a raiz e produziram
exatamente os efeitos solicitados.** O modelo local não foi executado.

## Método

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/cloud.toml
```

Uma repetição por cenário, em sequência, com bancos novos, depth máximo 1,
workspace em memória e alvo de exatamente três incrementos. O segundo caso
usa `in_progress` → `review` com agente reviewer. Não houve prazo de tarefa;
duração é somente uma métrica. O critério de sucesso foi conclusão da raiz
junto de exatamente três efeitos, retornando `[1,2,3]`.

## Resultados

| Cenário | Resultado | Runs | Avaliações do pai | Gates | Chamadas de modelo | Duração |
| --- | --- | --- | --- | --- | --- | --- |
| Sem fluxo | Raiz concluída; `[1,2,3]` | 4 | 1 | 0 | 5 | 42,50 s |
| Com review | Raiz concluída; `[1,2,3]` | 6 | 2 | 1 | 9 | 36,88 s |

Nos dois casos houve somente um filho. Não houve retries, breaks, falhas de
Run ou chamadas de ferramentas com erro. Todos os eventos de avanço/conclusão
observados tiveram aprovação explícita como causa: dois no caso sem fluxo,
três no caso com review. Os snapshots foram iguais após replay e todas as
Runs iniciadas tiveram encerramento registrado.

No caso com review, o harness avançou após a aprovação da implementação;
o reviewer executou na etapa `review`, e o pai aprovou seu relato antes da
conclusão do filho. A interseção entre capacidades do reviewer, perfil e depth
resultou em nenhuma ferramenta executável nessa Run. O reviewer avaliou o
contexto recebido com os critérios e evidências persistidas; não chamou
counter nem repetiu a implementação. A raiz consolidou e concluiu.

## Comparação e limite

Na campanha anterior sem prazo, o cloud sem fluxo concluiu após repetir os
incrementos em cinco filhos; o caso com review alterou o contador para 4 e
escalou ao humano. Esses comportamentos não apareceram nesta repetição após
as correções. Isso é evidência de melhora nos dois casos observados, não uma
estimativa de confiabilidade nem prova da contribuição isolada de cada mudança.

A amostra permanece pequena e restrita à tarefa de contagem e depth 1. Não
certifica processos complexos, outros depths ou o modelo local. A diferença
de duração entre os casos não constitui ranking de desempenho.

[Evidências sanitizadas](deepseek-after-corrections.json) contêm resultados,
eventos selecionados, identidade do commit e hash do script. Os bancos completos
ficaram em `/tmp/omunculus-stages-54995EB71B`.
