Status: TO-BE — planejado, não implementado

# Requisitos alvo

Este contrato é planejado e não está disponível na CLI atual. O ponto de
partida implementado está em [AS-IS requirements](../as-is/requirements.md).

## Ingress e autoridade

1. A entrada e a resposta públicas são CLI-only.
2. Cada comando aceito deve ser validado, receber identidade/idempotency key e
   ser persistido como envelope em `EVENTS` antes de qualquer dispatch.
3. Cada evento derivado deve ser append-only em `EVENTS` antes de dispatch;
   `EVENTS` não pode ser reduzido a uma fila transitória, outbox descartável ou
   cache.
4. O Event Core deve fornecer sequência/ordenação, correlation/causation,
   versão de schema, dedupe e replay determinístico.
5. Consumers/reducers devem tolerar redelivery, restart e replay sem duplicar
   efeitos confirmados; conflitos de versão devem ser observáveis e seguros.

## Trabalho e execução

1. `PROJECTS`, `WORK_ITEMS`, `COMMENTS`, `WORK_ITEM_DEPENDENCIES`,
   `ARCHIVE_RUNS` e `ARCHIVE_MODEL_CALLS` permanecem como as seis tabelas de
   domínio/archive; `EVENTS` é a tabela central adicional mínima.
2. Work Item é a unidade durável de trabalho. Run é uma tentativa durável e
   fechada; retry não reabre nem sobrescreve a Run anterior.
3. Agent é somente configuração genérica (identidade/kind, model/provider,
   prompt, tools, budget e params). Não pode conter `reports_to`, `parent` ou
   `depth` nem codificar uma árvore estática.
4. Delegação cria Execution Node/Run em runtime, com originador, parent e depth
   próprios. Reporting/hierarquia é derivado dessa árvore dinâmica e respeita
   limites de profundidade/recursão.
5. Chamadas de modelo, resultados e checkpoints devem ser relacionados à Run e
   ao Work Item por referências duráveis; efeitos externos precisam de estado
   idempotente suficiente para não reexecutar um efeito confirmado.

## Recuperação e operação

Após falha, o sistema deve reconstruir projeções a partir de `EVENTS`, retomar
somente trabalho elegível e distinguir efeito concluído de efeito desconhecido.
O CLI deve expor respostas/resultados duráveis e erros de conflito de forma
repetível. Persistência e replay não devem alterar o contrato público para
HTTP, MCP ou TUI: essas superfícies não fazem parte do alvo.

Envelope e dispatch normativos estão em [event-model.md](event-model.md); as
entidades e vínculos de runtime estão em [execution-model.md](execution-model.md).
