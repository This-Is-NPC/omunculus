# Observação por desfecho do protocolo

Correção metodológica de 2026-09-08. O teste não usa duração para decidir
sucesso, falha ou encerramento da tarefa. `elapsed_ms` é somente uma métrica.
Os relatórios e JSONs históricos foram anotados como interrompidos pelo
experimento, com conclusão inconclusiva; os dados observados foram preservados.

## Critérios

- `protocol_outcome = completed`: o harness emitiu `task.completed` para a
  raiz. A comparação externa dos efeitos indica se o resultado atende ao
  pedido. Aprovação do modelo e correção dos efeitos são medidas separadas.
- `protocol_outcome = awaiting_human`: o protocolo criou um pedido de
  avaliação humana. A tarefa fica pendente de decisão; não é uma falha
  por tempo nem uma conclusão automática.
- Sem um desses eventos, a observação continua. Falha de uma Run, conclusão
  de filho ou break encaminhado ao pai não encerram o cenário.
- Uma interrupção externa do processo deixa a conclusão inconclusiva.
  Efeitos incorretos já observados continuam sendo achados válidos.

`task_success` indica que foram observadas tanto conclusão da raiz quanto
conformidade dos efeitos. `false` com `awaiting_human` significa sucesso
não estabelecido, não reprovação automática da tarefa. `effect_success`
compara apenas os efeitos registrados. `approvals_checked` explicita quando
a checagem estrutural de aprovações não observou nenhum evento.

O observador está em [workflow_observer.exs](../../scripts/support/workflow_observer.exs).
Dois testes controlados verificam que falhas de tentativas e breaks parentais
não o encerram, que ele aguarda a raiz e que reconhece intervenção humana
sobre um filho. Esses testes passaram; não atestam a qualidade do modelo.

## Execução

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/cloud.toml
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml
```

Um caso específico pode ser selecionado acrescentando `plain` ou `staged`.
Sem seleção, os casos de cada comando são sequenciais. Cada caso tem banco
novo e dura até um desfecho observado, sem limite global de segundos. O
runtime conserva seus limites de tentativas e de turnos configurados.

A nova campanha foi iniciada com dois processos, um por provider. Suas
medições de duração não constituem comparação de latência controlada.
Evidências locais:

- Cloud: `/tmp/omunculus-stages-4C326589F6`
- Local: `/tmp/omunculus-stages-CF84CDE8E3`

Este registro documenta o início da campanha, não seus resultados finais.
Na última inspeção feita ao redigir este documento, ambos os casos `plain`
continuavam abertos. O cloud tinha repetido delegações após aprovar filhos;
o local estava avaliando uma entrega após retry. Os processos não foram
interrompidos para produzir este registro. Cada caso escreve `result.json`
ao observar conclusão ou intervenção humana; o banco preserva os eventos
durante a execução. Ausência desse resultado não deve ser convertida em
falha por duração.
