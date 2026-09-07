# Relato de Run, retries e break

Implementado em 2026-09-07. Este contrato completa o controle de trabalho
previsto no modelo de execução. A avaliação semântica pertence aos agentes.

## Encerramento e comentário

Execuções com o resolver de chat usam o protocolo v2. A resposta final do
modelo é um objeto JSON com `completed` booleano e `comment` não vazio:

```json
{"completed":false,"comment":"O arquivo foi criado. Falta revisar as referências; continue a partir dele."}
```

O comentário é simultaneamente resumo e orientação para a próxima Run.
Não existe um campo separado de instrução de correção. `break: true` é
opcional e solicita intervenção imediata; exige `completed: false`.
Campos desconhecidos, flags com tipos errados e comentários vazios são erros
de formato. O Agent fornece feedback dentro do limite de turnos. Esgotar
esse limite não transforma o trabalho em sucesso.

Uma chamada que termina a Run (`delegate`, `request_work`,
`request_permission`) exige o argumento `comment` antes de produzir o
pedido. O checkpoint conserva as mensagens e os vínculos de tool calls.
`run.completed.comment` é projetado em `COMMENTS`, com `kind = run`.
Arbitragem de permissões mantém seu protocolo de grant/deny/escalate e
registra o comentário disponível; não é uma decisão de conclusão da tarefa.
Falhas técnicas podem impedir a produção de comentário pelo modelo: o log
registra explicitamente a falha e o break leva um diagnóstico técnico, sem
inventar uma avaliação semântica.

Encerrar uma Run não conclui automaticamente o Work Item. No protocolo v2,
`run.completed` com `outcome = reported` grava o relato e o checkpoint. O
Runtime entrega `task.completed` quando `completed = true`. Um filho que
relata conclusão ainda será avaliado pelo pai na continuação.

## Correção automática

- Sem dependências pendentes, `completed = false` agenda uma retry do mesmo
  Work Item com o comentário e o checkpoint. Não reabre a Run anterior.
- Se a resposta avalia a última entrega de um filho, o comentário de
  reprovação é encaminhado à nova tentativa desse filho. `task.reopened`
  registra a revisão de uma conclusão anterior, preservando o histórico.
- Havendo outros filhos pendentes, a Run permanece em `waiting`: seu texto
  serve de nota, e a espera não consome retries. Novos pedidos podem ser
  feitos pelas ferramentas existentes.
- O próximo system prompt é recomposto para a Run atual; o restante das
  mensagens e o estado das tools são preservados. Comentários não concedem
  ferramentas nem alteram autoridade.

`max_turns` limita chamadas dentro da Run. `max_retries` limita tentativas
adicionais de correção: o default é 2, portanto uma execução inicial mais
até duas retries ordinárias. A precedência é agente, perfil, defaults.
Zero é válido; valores negativos ou não inteiros são rejeitados pelo config
check. As contagens são derivadas de `run.started` no log, não de processo
ou variável que zere ao reiniciar. `continuation` não é retry.

`task.retry_requested` persiste o agendamento antes de iniciar a próxima
Run. O executor reconstrói agendamentos sem ativação ao reiniciar. Eventos
redeliverados não duplicam a execução. Checkpoints mantêm efeitos confirmados;
falha técnica com efeito possivelmente desconhecido gera break para inspeção,
sem retry automática cega.

## Break e intervenção

Esgotadas as tentativas, ou quando o modelo pede `break`, o Runtime grava
`task.break` com alvo, comentário e responsável. O Work Item fica esperando;
a Run encerra. Nenhum processo espera a decisão de outro agente ou humano.

O responsável é o pai runtime do Work Item; sem pai, o destino é o humano.
Uma Run do responsável com `reason = break` recebe a tarefa original, o
comentário, comentários recentes e o estado confirmado das tools do alvo.
O checkpoint e as pendências do responsável são guardados para restauração.
A avaliação pode usar suas tools de leitura permitidas; não reexecuta o
trabalho como parte da arbitragem.

O relato do responsável tem os mesmos campos:

- `completed = true`: reconhece a conclusão **do alvo** com sua justificativa,
  inclusive quando o executor produziu o efeito mas falhou ao relatá-lo.
- `completed = false`: autoriza uma tentativa adicional do alvo usando seu
  comentário, sem zerar o histórico de retries.
- `completed = false, break = true`: encaminha a questão ao responsável acima.

As intervenções também são limitadas: por alvo, cada responsável tem uma
avaliação inicial mais `max_retries` avaliações adicionais. Assim, sucessivas
autorizações de correção não criam um loop infinito. Esgotado esse limite,
o break sobe de nível. `task.break.resolved` registra a resolução de cada
pedido; reconhecer o alvo não conclui silenciosamente os ancestrais. Eles
continuam com suas pendências restauradas e avaliam suas próprias tarefas.

## Humano e inbox

Ao chegar ao humano, o break produz `task.commented` de `kind = request`.
A resposta aponta para o pedido específico. Exemplos:

```sh
omunculus inbox --db /tmp/session.sqlite3
omunculus inbox reply <id> "Continue a partir do arquivo existente e corrija as referências" --db /tmp/session.sqlite3
omunculus inbox reply <id> "Verifiquei o resultado; o trabalho já está concluído" --completed --db /tmp/session.sqlite3
```

Texto de orientação autoriza nova tentativa; `--completed` reconhece a
conclusão sem reexecutar efeitos e exige comentário. Internamente, a CLI
registra o mesmo contrato `completed/comment` para a confirmação. A resposta
fecha o pedido da inbox por referência, sem se confundir com uma concessão
de permissão. Pedidos humanos não expiram automaticamente.

## Compatibilidade e validação

O catálogo mantém eventos v1 para ler o histórico. `run.started`,
`run.completed` e `task.completed` do novo contrato usam v2. Resolvers fake
legados e injeções explícitas sem `workflow: true` preservam o protocolo v1
para reproduzir os testes anteriores. `probe_harness_resilience.exs` está
explicitamente marcado como baseline v1; não certifica o contrato novo.

A validação atual está em `workflow_test.exs`, `workflow_config_test.exs` e
nos testes de inbox. Cobre preservação de efeitos, correção pelo comentário
do pai, limites, reconhecimento sem reexecução, escalonamento multinível,
resposta humana, falha técnica, agendamento interrompido, reinício e replay.
Os testes usam respostas controladas pelo resolver de chat real. Eles
verificam o protocolo, não garantem qualidade de julgamento de um modelo.

A suíte e o smoke real estão registrados em
[validação do break](../spike/break-validation.md).
