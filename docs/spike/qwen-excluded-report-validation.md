# Qwen: interceptor sem o relatório final da Run

Sessão `session-572b018f397bc577`, Qwen 3.5 9B local, depth 1/plain, em
2026-09-09 (UTC). [Evidências](qwen-excluded-report-validation.json).

A política `exclude` foi aplicada diretamente ao evento entregue ao summarizer.
O log original permaneceu íntegro. Nenhum `interception.requested` recebeu campo
`input`. O comentário inicial de cada ator continha o próprio envelope
`run.completed`, com o mesmo ID, sem `payload.comment`, sem `payload.report` e
sem mensagens assistant sem tool calls no checkpoint. Chamadas, argumentos e
retornos das tools foram preservados, conferidos contra os eventos originais.

## Resultado

**Aguardando humano**, com valores reais `[1,2,3,4]` no mesmo Work Item. Houve
8 Runs (3 da tarefa, 5 do summarizer), 14 respostas do modelo, 4 recuperações de
Work Item e 1 resolução de interceptação. Todas as Runs fecharam; orçamento e
rebuild das projeções passaram. Duração de 217.104 ms é apenas métrica.
Os quatro argumentos do contador eram `{}`. Os agentes padrão atuais foram
usados pelo runner; tools foram montadas pelo TOML/políticas, sem frontmatter.

## O que o filtro revelou

1. O worker executou quatro incrementos **antes** da primeira interceptação,
   mas seu relatório final (evento 3048) afirmou três chamadas e valor 3.
2. O summarizer recebeu os retornos reais `1,2,3,4`, sem esse relatório. Em 3054,
   registrou quatro chamadas e valor 4, com `completed=true` para o resumo.
   Afirmou também “Work executed successfully”, inadequado para a meta de três
   incrementos: a contagem foi fiel, a avaliação do sucesso não foi.
3. O pai recebeu esse resumo e tentou delegar novamente. A tentativa encontrou
   o orçamento esgotado; sua Run terminou com break em 3066.
4. O summarizer recebeu essa segunda Run também filtrada. Nas quatro tentativas,
   voltou a marcar `completed=false` em função do trabalho original incompleto,
   até a interação escalar ao humano. O relatório final da fonte não era necessário
   para que essa confusão ocorresse: o histórico continha evidência da falha.

Excluir o relatório permitiu observar um resumo que contradisse corretamente a
contagem falsa do worker. **Não resolveu a distinção entre concluir um resumo e
concluir o trabalho resumido.** Não é uma comparação causal pareada: uma única
execução, com trajetória do worker diferente das campanhas anteriores. Comentários
históricos em mensagens de contexto continuam presentes; o filtro não apaga toda
menção a conclusões anteriores da sessão.

## Validação da implementação

374 testes passaram. Incluem exclusões no evento entregue, preservação do original,
respostas de tool e tool calls, retries, agente local, consulta por ator externo e
recuperação sem recriar resultados já persistidos. A primeira tentativa de execução,
antes da correção da entrega, parou durante recuperação do banco por conflito de
ID; não chegou a chamar o modelo nem integra esta amostra.

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml plain --depth 1 --interceptor on --interceptor-input without-report
./omunculus session replay session-572b018f397bc577 --db test/sessions.sqlite3 --ui narrative
```
