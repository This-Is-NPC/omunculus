# Interceptor agente entre Runs — Qwen local

Sessão `session-9db6c3dfb48bab83`, banco `test/sessions.sqlite3`, modelo
`qwen3.5:9b`. Cenário executado por `scripts/validate_interception.exs`, com o
agente `handoff-editor` e a regra de `examples/interception-agent.toml`.

## Resultado observado

- Conclusão pelo protocolo em 47,294 segundos; duração é métrica, não critério.
- Quatro Runs encerradas: worker → handoff-editor → reviewer → handoff-editor.
- Duas solicitações e duas resoluções de interceptação.
- Um único efeito do counter: `[1]`, usando argumentos `{}`.
- O reviewer recebeu o comment produzido pelo primeiro interceptor e começou
  depois da resolução persistida.
- Replay das projeções idêntico; nenhuma Run continua em execução.

A origem permaneceu intacta no log. O interceptor executou como agente normal,
com Work Item próprio, prompt e tools definidos no TOML. O Core não chamou o
modelo nem executou lógica especial de resumo. O `completed` do interceptor
concluiu apenas seu processamento; a flag do trabalho original foi preservada.

## Sequência verificável

| Evento | Sequência |
|---|---:|
| Worker iniciou | 2467 |
| Solicitação ao handoff-editor | 2475 |
| Run do handoff-editor iniciou | 2477 |
| Primeiro resultado resolvido | 2484 |
| Reviewer iniciou com o comment | 2488 |
| Segunda solicitação | 2492 |
| Segunda Run do handoff-editor | 2494 |
| Segundo resultado resolvido | 2501 |

Primeiro comment recebido pelo reviewer:

> Counter incremented to 1 as instructed. Evidence recorded: counter value is 1.

Esse texto é produção do Qwen, não veredito do harness. A etapa de review continuou
obrigatória e foi executada. O teste verifica transporte, ordem e efeitos; uma
execução não estima qualidade ou confiabilidade da sumarização em tarefas complexas.
O fingerprint dos arquivos `lib/**/*.ex` foi conferido contra a implementação final.

Uma execução anterior (`session-968160e7c309251d`) concluiu em cinco Runs, mas
revelou uma solicitação humana prematura quando o primeiro agente interceptor
falhou. A correção faz esse break retornar à interação proprietária antes do
roteamento humano. Um teste força a falha e confirma retry sem pedido humano
prematuro; a sessão final acima não contém solicitações humanas pendentes.
As métricas das duas execuções anteriores foram preservadas no artefato.

[Eventos completos e métricas](interception-qwen-validation.json).

```sh
./omunculus session replay session-9db6c3dfb48bab83 --db test/sessions.sqlite3 --ui narrative
mise exec -- mix run scripts/validate_interception.exs presets/local.toml
```

A cobertura automatizada adicional verifica ator externo via `emit`, duplicação,
rejeição de resposta incompatível, timeout opcional da interação, escalonamento,
respostas fora de ordem, cenário desativado, fechamento da Run solicitante antes
da resposta e recuperação após interrupção entre commits/entrega. Não foi usado
ator externo com modelo remoto nesta amostra real; o ator de resumo foi o agente
configurado, e a porta externa foi verificada por teste de integração.
