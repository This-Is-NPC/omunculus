# Work Item e comment entre Runs

Correção do contrato: o agente delega um Work Item, acompanhado de `comment`.
Não transmite uma instrução avulsa nem copia a tarefa da Run pai quando faltam
argumentos. A definição da tarefa pertence ao Work Item. Seu atributo textual
canônico atual é `instruction`; ele fica dentro de `work_item`, não é um segundo
argumento de delegação. IDs, parent ID, status/state e tentativas são do harness.

Entrada humana cria Work Item raiz. `delegate(work_item, comment)` registra
`task.delegated` com o Work Item filho e vínculo paterno. A Run pai encerra em
waiting; a Run filha recebe o Work Item e o comentário. Relato solicita avaliação
do responsável; sua aprovação avança a etapa ou conclui o Work Item. Retry e
continuação preservam a identidade e recebem o comentário atualizado.
`request_work` e mediação usam o mesmo objeto, sem canal paralelo de instruções.
Não há decoder, migração ou aceitação do argumento antigo de delegação.

## Recuperação limitada por trabalho

`max_retries` é orçamento durável do Work Item/etapa, não um contador que recomeça
em cada Run. A primeira execução/delegação e a primeira avaliação são normais.
Consomem recuperação: nova tentativa após relato incompleto; correção de chamada
ou relato inválido; delegação de verificação durante avaliação; nova delegação
em continuação depois de receber trabalho aprovado. Não se inferem equivalências
semânticas entre textos. Uma delegação inicial válida com vários filhos continua
permitida; receber cada resultado dessa delegação não consome uma tentativa.

Verificações e seus descendentes carregam a referência ao mesmo orçamento do
alvo, sem novo limite para cada filho. Reservas entram atomicamente em EVENTS,
antes da recuperação, e são idempotentes. Avanço de etapa inicia novo orçamento;
reinício não o renova. Esgotamento termina a Run com break e evidências preservadas.
O responsável pode aprovar efeitos existentes ou escalar; não obtém recuperações
ilimitadas delegando de novo. A avaliação semântica permanece com o responsável.

## Verificação

Testar rejeição do argumento avulso, zero filhos em handoff inválido, Work Item
correto na Run filha, comentário preservado, recuperação após restart, concorrência
na reserva, fan-out inicial legítimo, verificações sucessivas, erros dentro da Run,
continuações que redelegam e break até humano. Não usar prazo de tarefa como oracle.

## Contrato atual

```json
{
  "work_item": {"instruction": "Incrementar o contador três vezes e registrar os valores."},
  "comment": "Delegando a execução; avaliarei os valores retornados."
}
```

`team`, `agent` e, em request_work, `workspace`, são seletores de roteamento.
A entrada humana ainda recebe texto para criar a tarefa raiz; isso não é um
formato alternativo de handoff. A Run recebe sua definição e comentário; o
adaptador do modelo os apresenta na mensagem de entrada. Checkpoints pertencem
à execução e não constituem uma instrução alternativa enviada por outro agente.
Avaliação e mediação preservam o Work Item e colocam seu contexto no comment.

Reservas são anteriores à tentativa, inclusive quando ela resulta em rejeição.
Uma resposta que corrige vários erros da mesma rodada consome uma recuperação;
chamadas válidas normais não consomem. Não há tabela nova, fallback ou migração.

Verificado: **344 testes, zero falhas**, incluindo concorrência entre dois
clientes do mesmo banco, deduplicação após limite esgotado, reinício, isolamento
por etapa e as regressões de delegação/continuação/relato. A validação real
histórica e seus limites estão no [relatório](../spike/current-harness-validation.md).

Smoke DeepSeek sem workflow, depth 1: `[1,2,3]`, 4 Runs fechadas e aprovação
causal do pai. Replay idêntico após retirar sessões incompatíveis do banco ativo,
preservadas no arquivo histórico. A matriz completa e o Qwen aguardam revalidação.
