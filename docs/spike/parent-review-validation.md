# Validação do protocolo de revisão pelo pai

Registro histórico anterior ao contrato de `completed/comment`, retries e break.
O script atual foi migrado para esse contrato; veja
[relato, retries e break](../to-be/run-report-and-break.md). As revisões v1–v3
deste relatório são revisões de prompt, não versões do catálogo de eventos.

Data: 2026-09-07. Objetivo: oferecer aos agentes instruções para delegar,
relatar evidências, avaliar e pedir correção, preservando sua decisão
semântica. Não foi adicionado gate de qualidade ao runtime.

## Implementação

- `Runtime.Prompt` compõe protocolo comum, papel configurado, posição,
  workspace e instruções do perfil. O executor aplica as instruções; o pai
  as transmite e usa na avaliação. Ferramentas do pai não descrevem as do filho.
- O protocolo explica que entrega do filho não aprova o trabalho do pai,
  e que uma nova delegação pode pedir correção ou verificação.
- As fixtures de coordenação deixam de mandar apenas repetir a resposta.
- O schema de `delegate` explica retomada/revisão e seletores opcionais:
  omitir `agent` e `team` usa o roteamento configurado.
- `Agent` preserva instruções extras mesmo com system prompt customizado.
  O resolver compõe o perfil diretamente no system prompt; não depende
  de `agent.instructions`. Checkpoints mantêm as mensagens sem duplicação.

Não foram alterados estados de conclusão, política de ferramentas, critérios
de aprovação, retries ou nudges de contagem. Contextos antigos não recebem
retroativamente o novo system prompt; os testes criam Work Items novos.

## Verificação determinística

282 testes passaram na versão final. Os novos testes inspecionam as mensagens
recebidas pelo chat para coordenador e executor, verificando perfil, papel e
preservação do checkpoint. O probe metodológico agora registra
`system_contains_profile=true`. Os nove cenários controlados de resiliência
preservaram suas observações, incluindo revisão pelo pai e os limites de
recuperação técnica já documentados.

A suíte revelou também expectativas antigas dos presets e uma corrida na
matriz: `Runtime.request` pode retornar após `task.completed` e antes do
último `run.completed`. Os testes foram corrigidos em commits separados;
a matriz agora aguarda Runtime sem Runs antes de comparar os eventos.

## Cenário com provider real

[Script](../../scripts/validate_parent_review.exs) e
[resultados por tentativa](parent-review-results.ndjson).

O cenário usa `complex.toml` + lane, raiz somente `delegate` no perfil count,
máximo depth 2, contador em memória e banco isolado. O primeiro filho de
depth 1 recebe uma resposta simulada: não executou counter e não tem
evidências. Todas as outras respostas vêm do provider selecionado, incluindo
a decisão do pai sobre essa entrega. Alvo: contar com counter até 3.

O experimento não é inteiramente real nem mede desempenho de modelos. Testa
a reação de agentes reais a uma perturbação reproduzível do workflow. O
timeout do cliente é 180 s; o writer é parado antes da coleta final.
`client_success` significa retorno do runtime, não aprovação pelo benchmark.
`correction_cycle_observed` requer entrega incompleta, nova delegação aceita
após ela, sequência 1..3 em um Work Item e retorno da raiz. O texto final e
as demais sequências também precisam ser examinados; o indicador não é um
verificador semântico universal.

As tentativas ocorreram sequencialmente. Não há seed, repetição balanceada
ou comparação estatística antes/depois; não inferir taxa de confiabilidade
nem atribuir toda diferença à edição de prompt. Revisões registradas:

| Revisão | Condição | Observação |
| --- | --- | --- |
| v1: protocolo inicial | Local | Tentou `agent=counter` sem team; após rejeição e entrega incompleta, encerrou com bloqueio. Zero incrementos; 80,7 s |
| v2: roteamento padrão explícito | Local | Pediu correção, mas aceitou “2” para alvo 3; apenas um incremento real. 52,8 s |
| v2: mesma revisão | Cloud | Não delegou: interpretou a ausência de counter nas próprias tools como bloqueio. 31,5 s |
| v3: ferramentas por posição explícitas | Cloud | Pediu correção da entrega incompleta; depois identificou overshoot até 4 e pediu outra execução. Nova sequência 1..3 e resultado final 3. 71,5 s |
| v3: mesma revisão final | Local | Recebeu a entrega incompleta e descreveu intenção de redelegar, mas não chamou delegate novamente. Inferiu indisponibilidade de counter sem evidência; zero incrementos. 117,9 s |

No sucesso cloud, as duas execuções produtivas ocorreram em depth 1, apesar
do papel configurado pedir delegação a worker. Portanto, o teste demonstra
revisão e retrabalho pelo pai, mas não conformidade à cadeia de três níveis.
O resultado final veio em italiano embora o pedido fosse em português.
Ambas as limitações permanecem registradas; o sucesso numérico não as apaga.

## Interpretação e próximo passo

O caminho de revisão pelo pai funciona também com decisões reais: a execução
cloud corrigiu inclusive um erro não injetado, a contagem além do alvo. Isso
sustenta a arquitetura de avaliação pelos agentes; não exige transformar
qualidade em uma regra determinística do runtime.

Os prompts anteriores omitiam funções essenciais e instruções do perfil.
Essas lacunas foram corrigidas, mas os resultados ainda não demonstram
confiabilidade geral. Na tentativa local final, a continuação chegou e o
agente reconheceu textualmente a necessidade de correção, mas sua resposta
não incluiu a chamada de ferramenta. Isso localiza a quebra observada na
decisão/ação do agente nessa continuação, não em uma Run bloqueada ou perda
da resposta do filho. Não prova incapacidade geral do provider, nem elimina
possíveis melhorias de prompt ou contexto.

A próxima campanha deve manter o protocolo e o projeto
de referência fixos, separar raiz/intermediário somente delegação de
intermediário executor e testar evidências incompletas ou contraditórias,
com repetições por cenário. Falha HTTP e retomada técnica são uma dimensão
separada da revisão de uma entrega recebida.

```sh
mise exec -- mix test
# Probe metodológico antigo removido; use os testes do contrato atual.
# Probe de protocolo antigo removido; use os testes do contrato atual.
mise exec -- mix run scripts/validate_parent_review.exs presets/local.toml
mise exec -- mix run scripts/validate_parent_review.exs presets/cloud.toml
```
