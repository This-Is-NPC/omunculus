# Validação de relatos, retries e break

Data: 2026-09-07. Implementação e configuração descritas em
[relato, retries e break](../to-be/run-report-and-break.md).

## Verificação do harness

A suíte completa terminou com **296 testes e zero falhas**. Os testes novos
exercitam o resolver de chat real com respostas controladas, sem substituir
a implementação de delegação ou a máquina de estados:

- Retry automática com o comentário anterior e contador preservado (1 → 2).
- Reprovação pelo pai retomando o filho, sem repetir o primeiro incremento.
- Reconhecimento de conclusão pelo pai em uma Run de break, sem reexecutar.
- Escalonamento por dois responsáveis até o humano.
- Limites duráveis de retries e de intervenções; continuação não conta como retry.
- Comentário obrigatório antes de um pedido criar efeitos.
- Falha técnica escalada para inspeção, sem retry automática cega.
- Dois filhos com break, preservando as pendências do pai.
- Reinício antes de ativar uma retry já agendada e depois de chegar ao humano.
- Replay das projeções e redelivery sem duplicar efeitos ou tentativas.
- Retomada explícita que conclui o trabalho e fecha o pedido humano antigo.
- Configuração de kind, camadas de prompt, agentes padrão e precedência de limites.
- Resposta humana por `inbox reply --completed`, com comentário e referência ao pedido.

Esses testes verificam transições, contexto e efeitos observáveis. Não
aprovam semanticamente uma entrega nem demonstram confiabilidade geral de
modelos pequenos. Os eventos v1 e os testes legados continuam aceitos para
compatibilidade; os novos testes exercitam o protocolo v2.

## Smoke com cloud

[Resultado](break-cloud-validation.json) e
[eventos selecionados](break-cloud-events.json). A campanha anterior de
prompts permanece histórica; esta execução usa o contrato estruturado.

O script `validate_parent_review.exs` injeta somente a primeira entrega
incompleta de depth 1, agora com `completed=false`, comentário e `break=true`.
O pai e as execuções seguintes usam o provider real. Workspace e banco são
isolados; o teste pede contagem até 3. O executor é parado antes da coleta.

Foi observado:

1. A raiz delegou com comentário de handoff.
2. O filho encerrou com relato incompleto e gerou break.
3. O pai foi reativado com `reason=break`; retornou `completed=false` e
   orientações no comentário, sem uma nova chamada de delegate.
4. O harness persistiu `task.retry_requested`, resolveu o break e abriu
   uma Run do filho com `reason=retry` e o comentário do pai.
5. O filho efetuou quatro incrementos (1, 2, 3, 4). Não houve relato final
   dessa retry antes do limite de 180 segundos imposto pelo teste.

**Resultado funcional: falhou por timeout; a sequência excedeu o alvo.**
Não houve `task.completed` nem conclusão falsa emitida pelo harness nessa
rodada. Também não houve `run.failed` antes da interrupção pelo runner.
A avaliação do pai levou aproximadamente 64,4 s; esse tempo faz parte do
orçamento global, não de uma espera bloqueante entre Runs.

O comentário do pai dizia para chamar counter para “0, 1, 2 e 3”, embora
esperasse resultado final 3. Isso evidencia uma orientação ambígua/incorreta
sobre uma ferramenta que incrementa a cada chamada. O fluxo estrutural foi
confirmado, mas a qualidade da correção e a conclusão do cenário não foram.
Não atribuir esta única execução a incapacidade geral do provider ou a uma
taxa de confiabilidade do harness.

A coleta ocorreu antes do ajuste final que alinha as ferramentas pinadas de
uma Run de break com o subconjunto de leitura já exposto ao modelo; a suíte
final cobre esse alinhamento. Não houve nova campanha local nesta alteração.

## Reprodução

```sh
mise exec -- mix test
mise exec -- mix run scripts/validate_parent_review.exs presets/cloud.toml
```

O próximo benchmark deve manter tarefa, contexto e orçamento fixos, repetir
casos por configuração e distinguir protocolo cumprido, efeito correto,
intervenção necessária e timeout. Uma execução encerrar não equivale a
aprovação do resultado.
