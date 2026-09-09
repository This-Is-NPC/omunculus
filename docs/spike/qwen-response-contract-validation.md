# Qwen: contrato próprio da interceptação

Validação em 2026-09-09, `qwen3.5:9b`, depth 1, interceptor habilitado,
excluindo relatório final e mensagens assistant sem tool calls na entrega.
Sessão `session-4b4445d615ccdeaa`, banco `test/sessions.sqlite3`.
[Métricas e respostas](qwen-response-contract-validation.json).

## Correção

A Run de processamento usa o `response` persistido na regra. Aqui retorna somente
`comment`, sem contrato de execução `completed/comment/break`. Resposta válida
resolve a interação mesmo quando descreve uma tarefa incompleta. O adaptador
encerra o Work Item de processamento; somente o pai julga a tarefa original.
Falhas técnicas ou de formato usam o orçamento da interceptação, sem retries
internos ou avaliação de workflow do resumidor. Não há ação de resumo hardcoded.

## Resultado real

- 6 solicitações, 6 Runs de ator, 6 respostas aceitas e 6 resoluções.
- Todas as respostas contêm somente `comment`; nenhum retry ou break do ator.
- 15 Runs totais, 9 da tarefa, 22 chamadas de modelo; todas as Runs encerradas.
- A tarefa terminou em intervenção humana, não em sucesso.
- Efeitos: `[1,2,3,4,1,2,3]`, distribuídos por dois Work Items.
- Replay equivalente, argumentos do counter válidos e recuperações limitadas.
- Duração observada: 422,5 segundos. Não é critério de sucesso/falha.

O primeiro worker executou quatro incrementos, mas relatou três. Sem esse relato
na entrada, o resumidor identificou corretamente quatro e transmitiu a divergência
ao pai. O pai delegou uma nova execução, que produziu três incrementos em outro
Work Item; isso não desfaz os quatro anteriores. Também voltou a delegar confirmação.
O limite de recuperação levou a intervenção humana.

O último processamento também descreveu a divergência quatro versus três e foi
aceito na primeira tentativa. Antes da correção, a descrição de falha podia produzir
`completed=false` no resumidor e desencadear retries internos mais retries da
interceptação. Nesta sessão, nenhuma resposta precisou desse ciclo.

Isso confirma a separação de contratos, não a fidelidade de todo texto produzido:
resumos intermediários ainda empregaram linguagem de aprovação e repetiram alegações
de evidência do contexto. O conteúdo continua sendo uma saída não determinística;
o harness valida o formato, e o pai precisa avaliar a evidência real. Uma sessão não
constitui estimativa de taxa de sucesso do modelo ou do harness.

## Reprodução

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml plain --depth 1 --interceptor on --interceptor-input without-report
```

O auditor distingue a conclusão técnica do Work Item de processamento das
aprovações de tarefas. As aprovações continuam exigindo relato e autoridade do pai;
a conclusão do ator exige uma resposta válida ao contrato da interação.

Verificação automatizada final: `mix test`, 379 testes, zero falhas; escript
recompilado. A cobertura inclui fonte incompleta, resposta inválida seguida de
retry da interação, contexto filtrado, ausência de retries/breaks internos,
booleano `false` como dado configurável e replay. Durante testes concorrentes com
build/modelo, dois testes existentes excederam limites temporais; o teste de equipes
passou isolado e a suíte completa passou após o encerramento dessa carga.
