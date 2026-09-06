Status: TO-BE — planejado, não implementado

# Modelo de execução e delegação

Este documento define as entidades de runtime. Persistência e envelopes estão
em [data-model.md](data-model.md) e [event-model.md](event-model.md).

Para a comparação do modelo de delegação com Pi, Claude Code e Codex, veja
[harness-comparison.md](harness-comparison.md).

## Agent como configuração

Agent é uma configuração genérica, identificada por `agent_id` e versão/hash,
com `kind`, model/provider, prompt, tools, budget e params. Um snapshot pode
ser pinado em um Work Item ou Run. `kind` descreve capability; inclusive
`supervisor` não é parent nem relação de reporte. A configuração **não** possui
`reports_to`, `parent` ou `depth`.

## Entidades de runtime

- **Work Item**: agregado durável de trabalho, com projeto, instrução, estado,
  versão otimista, dependências e checkpoint.
- **Execution Node**: instância transitória/lógica criada para uma execução;
  identifica originador, parent runtime opcional, depth e Agent config pinado.
  Parent e depth pertencem ao node, não ao Agent.
- **Run**: tentativa durável de um Execution Node executar um Work Item. Tem
  identidade, attempt, trace, status, timestamps e vínculo opcional à Run
  parent. Run só nasce quando a execução inicia; retry gera outra Run.
- **Session**: processo OTP efêmero que atende uma Run ativa, se a
  implementação usar processo para isso. Não é a fonte de estado durável.

A mesma configuração Agent pode aparecer em nodes com parents/depth diferentes
em execuções diferentes.

## Delegação e árvore dinâmica

Quando uma Run delega, o runtime valida orçamento, profundidade máxima,
aciclicidade e dependências e cria um novo Execution Node/Run com
`originating_run_id`, `parent_run_id`/vínculo equivalente e `depth = parent.depth
+ 1`. A relação de reporting é derivada dos vínculos das instâncias criadas;
não há uma árvore declarada no arquivo de Agent. Um node raiz possui depth 0.

```mermaid
graph TD
    A[Agent config] --> R0[Execution Node/Run depth 0]
    R0 -->|delegação| R1[Execution Node/Run depth 1]
    R1 -->|delegação| R2[Execution Node/Run depth 2]
    R0 -. usa a mesma configuração .-> A
    R2 -. reports para .-> R1
```

A árvore pode ser vista como projeção de Runs e eventos de delegação. Fechar um
node não apaga seus eventos; falha, cancelamento e crash deixam status durável.

## Work Item e controle

Uma Run recebe um Work Item elegível, configurações pinadas e checkpoint
bounded. Claims e transições usam versão/ownership para evitar duas execuções
concorrentes. Conclusão, pausa/break, invalidação, archive, erro e retomada
são comandos/eventos persistidos pelo [Event Core](event-model.md). Uma retomada
cria uma nova tentativa; não reabre a Run anterior.

O contexto de uma Run pode incluir chamadas de modelo, observações de tools e
metadados de efeitos. Efeito externo confirmado é reproduzido sem reexecução;
efeito desconhecido exige decisão antes de continuar. O modelo não recebe
permissão para escapar do sandbox apenas por delegar.
