# Reavaliação local após as correções

Execução sobre `de91dac`, com `qwen3.5:9b` pelo preset local. O código de
runtime e o script são os mesmos da reavaliação DeepSeek sobre `32eaac7`;
o commit intermediário contém apenas documentação.

## Método

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml
```

Uma repetição por cenário, sequencialmente, bancos novos, depth máximo 1,
workspace em memória e alvo de três incrementos, retornando `[1,2,3]`.
O segundo caso configura `in_progress` → `review`. Sem prazo de tarefa:
duração é métrica, e o observador encerra na conclusão da raiz ou solicitação
de intervenção humana. As duas execuções encerraram; nenhuma Run ficou ativa.

A primeira tentativa foi bloqueada pelo sandbox com `Req.TransportError`
`:eperm`, antes de acessar o provider. Seus bancos estão em
`/tmp/omunculus-stages-2B1CEA843E`; ela foi excluída da avaliação do modelo.
A campanha abaixo foi reiniciada com acesso autorizado ao servidor local.

## Resultados

| Cenário | Resultado | Efeitos | Runs | Chamadas de modelo | Duração |
| --- | --- | --- | --- | --- | --- |
| Sem fluxo | Raiz concluída | `[1,2,3]` | 4 | 7 | 73,04 s |
| Com review configurado | Intervenção humana antes da delegação aceita | Nenhum | 3 | 13 | 172,20 s |

Sem fluxo: um filho executou os três incrementos; o pai aprovou e consolidou
a conclusão. Não houve erros de ferramenta, retries, breaks ou falhas técnicas.
As duas conclusões tiveram aprovação explícita como causa e o replay foi igual.
O relato final informa o valor 3, mas não enumera cada valor retornado; o log
confirma `[1,2,3]`. O texto também afirma “stage advanced”, embora não houvesse
workflow nem evento de avanço. O sucesso medido não implica relato impecável.

Com review configurado: o concierge tinha somente `delegate`. Houve nove
respostas `handoff_comment_required` e uma rejeição `agent not in session`
para `counter_worker_01`. Algumas chamadas traziam argumentos malformados,
incluindo fragmento de marcação em uma chave. O modelo atribuiu o problema à
falta de `agent`, embora os erros predominantes indicassem falta de `comment`.
O schema montado pelo runtime exige `comment`; `agent` é opcional, com orientação
para omiti-lo quando não houver seletor conhecido. O system prompt também
explica o comentário obrigatório e proíbe inventar nomes.

Após três Runs da raiz (inicial e dois retries), todas reportando
`completed=false`, o harness emitiu `break` e solicitou intervenção humana.
Nenhum filho foi criado, nenhum contador executou e o gate de review não foi
alcançado. Não houve falha técnica de Run. O replay foi igual; não houve
aprovações a validar (`approvals_checked=0`), portanto `approvals_valid=true`
nesse caso não evidencia aprovação de trabalho.

Os dez erros de ferramenta foram contados nas respostas dos checkpoints,
deduplicadas por `tool_call_id`. Contar apenas eventos `tool.call.completed`
com erro perderia essas rejeições anteriores à execução. Um evento
`task.delegated` rejeitado também não equivale a um filho efetivamente criado.

## Interpretação e próximo experimento

O local conseguiu executar o fluxo simples. Na outra amostra, o bloqueio
observado foi a formação de chamadas de delegação e a recuperação após feedback,
antes de testar a máquina de estados ou o reviewer. O harness preservou as
restrições e escalou após os retries configurados; não declarou conclusão falsa.
Isso não prova que o review causa a dificuldade nem permite atribuí-la
exclusivamente aos pesos do modelo: a captura mostra o resultado recebido pelo
harness, sem isolar template, parser de ferramentas e configuração do servidor.

O DeepSeek concluiu ambos os casos na amostra anterior; o local concluiu um e
escalou outro. Uma repetição por cenário não estima confiabilidade nem certifica
processos complexos. O próximo experimento útil é repetir o mesmo contrato de
delegação com captura de request/response sanitizada no limite do provider,
para separar geração, parsing e recuperação, mantendo os mesmos critérios.

[Evidências sanitizadas](local-after-corrections.json) incluem resultados,
erros de chamada, eventos selecionados, commit e hash do script. Bancos completos:
`/tmp/omunculus-stages-CFFE7AF78E`. Comparação:
[DeepSeek após as correções](deepseek-after-corrections.md).
