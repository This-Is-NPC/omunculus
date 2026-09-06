Status: TO-BE — planejado; itens marcados *(spike)* validados na branch `spike/event-core`

# Requisitos alvo

Este contrato é planejado e não está disponível na CLI de `main`. O ponto de
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
   fechada; retry não reabre nem sobrescreve a Run anterior. Uma Run nunca
   espera outro agente ou um humano: pedir é concluir, com
   `outcome = waiting` e checkpoint, e a resposta abre uma Run nova.
3. Agent é somente configuração genérica (identidade/kind, model/provider,
   prompt, tools, budget e params). Não pode conter `reports_to`, `parent` ou
   `depth` nem codificar uma árvore estática.
4. Delegação cria Execution Node/Run em runtime, com originador, parent e depth
   próprios. Reporting/hierarquia é derivado dessa árvore dinâmica e respeita
   limites de profundidade/recursão.
5. Chamadas de modelo, resultados e checkpoints devem ser relacionados à Run e
   ao Work Item por referências duráveis; efeitos externos precisam de estado
   idempotente suficiente para não reexecutar um efeito confirmado.

## Catálogo, interceptores e automações

1. Todo tipo de envelope é declarado uma vez no catálogo, com `kind`,
   versões de schema, payload obrigatório e as marcas `interceptable` e
   `injectable`. O Core rejeita append fora do catálogo. *(spike)*
2. Interceptores são configurados por tipo de evento, rodam após o commit e
   antes da entrega, e só podem entregar ou rejeitar. Rejeição vira
   `delivery.rejected` com causação no envelope barrado. *(spike)*
3. Automações são consumidores externos assíncronos com cursor durável,
   entrega at-least-once e sem poder de veto. *(spike)*
4. De fora só entram comandos marcados `injectable`, pela CLI; para fora só
   saem eventos, pela leitura ordenada do log. *(spike)*
5. Um interceptor pode ser restrito por `workspace_id` e uma automação só
   pode pedir os perfis e workspaces que a configuração lhe deu.

## Sessão e workspaces

1. Session é agregado durável com `session_id` próprio, distinto de
   `correlation_id`; um log por sessão.
2. Workspace é membro da sessão por `workspace.attached`/`detached` e
   identidade do Execution Node de depth 1; nodes de depth 0 e 1 têm
   identidade derivada e são reutilizados entre Runs.
3. Trabalho entre workspaces é um Work Item no destino, criado sob a
   autoridade do depth 0, ligado por `WORK_ITEM_DEPENDENCIES`; não existe
   canal direto entre nodes de mesmo depth.
4. O humano só escolhe sessão e workspace quando quer; por padrão fala com
   o concierge de depth 0, que roteia. Toda pergunta ao humano é
   `COMMENTS` com `kind = request` e toda resposta é comando; a inbox é a
   projeção dos pedidos abertos e dos resultados não lidos.

## Política de tools e permissões

1. O conjunto de tools de um nó é a interseção, faixa a faixa, de teto por
   posição, teto por workspace e perfil, resolvida a partir do config
   **antes de cada Run**; é pinado em `run.started` como lista expandida e a
   política vigente fica em `policy.loaded`. Edição do config vale para a
   próxima Run e nunca altera uma Run em andamento.
2. Modos `allow` e `deny` decidem apenas o padrão do que não foi escrito;
   após normalização não existem curingas.
3. A permissão é aplicada em exposição, execução e entrega, de forma
   independente, lendo o mesmo conjunto pinado.
4. Delegação nunca amplia: o filho herda a autoridade do pai.
5. Crescer durante a execução exige `permission.requested` arbitrado por
   quem tem autoridade, temporária para a tarefa solicitante e seus
   descendentes ou permanente; permanente é mudança de
   configuração registrada no log. Um pedido não tem vida útil: fica aberto
   até ser concedido ou negado.

## Recuperação e operação

Após falha, o sistema deve reconstruir projeções a partir de `EVENTS`, retomar
somente trabalho elegível e distinguir efeito concluído de efeito desconhecido.
O CLI deve expor respostas/resultados duráveis e erros de conflito de forma
repetível. Persistência e replay não devem alterar o contrato público para
HTTP, MCP ou TUI: essas superfícies não fazem parte do alvo.

Envelope e dispatch normativos estão em [event-model.md](event-model.md); os
tipos em [event-catalog.md](event-catalog.md); as entidades e vínculos de
runtime em [execution-model.md](execution-model.md); sessão e workspaces em
[session-model.md](session-model.md); tools e permissões em
[tool-policy.md](tool-policy.md) e
[permission-negotiation.md](permission-negotiation.md).
