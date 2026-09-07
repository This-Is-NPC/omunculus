Status: validado em 2026-09-07 — infraestrutura; resultados do modelo discriminados

# Fase 7: sessão residente e provider real

Execução reproduzível:

```sh
mise exec -- mix run scripts/validate_real_matrix.exs
```

O script isola cada fixture e filesystem em /tmp, carrega simple, medium e
complex com e sem lane e usa o preset local (qwen3.5:4b).
Endpoint observado: FastFlowLM em localhost:52625/v1. Não houve substituição
por fake nem afrouxamento da política. Tarefas: “conte até 10” e “escrever um README”.

Critério funcional: dez tool calls counter concluídas ou README.md existente
no workspace, além do encerramento da tarefa. Texto afirmando conclusão não
basta. Replay compara snapshots das projeções.

| Fixture | Tarefa | Lane | Efeito observado | Sucesso funcional | Replay igual |
| --- | --- | --- | --- | --- | --- |
| simple | count | não | 10 | sim | sim |
| simple | count | sim | 10 | sim | sim |
| simple | write | não | true | sim | sim |
| simple | write | sim | true | sim | sim |
| medium | count | não | 0 | não | sim |
| medium | count | sim | 0 | não | sim |
| medium | write | não | true | sim | sim |
| medium | write | sim | false | não | sim |
| complex | count | não | 0 | não | sim |
| complex | count | sim | 0 | não | sim |
| complex | write | não | false | não | sim |
| complex | write | sim | false | não | sim |

Resultado: 5/12 efeitos comprovados, 12/12 replays idênticos. O caso medium
write sem lane delegou ao depth 1 e retomou o concierge. Nos demais casos
medium/complex sem efeito, o modelo respondeu sem delegar; complex write
com lane consultou directory e depois devolveu texto. Portanto a configuração
de três níveis foi exercitada, mas esta execução real **não comprovou uma
cadeia de três níveis**. Essa cadeia está coberta pelo provider fake.

A resposta de contagem simple também incluiu prosa, contrariando “somente
o número”, apesar das dez chamadas efetivas. Esses achados são deriva de
instrução observada, não autorização para o runtime fabricar tool calls.
O critério transversal do plano permite registrar falhas do modelo sem
transformá-las em falhas dos testes determinísticos.

[Resultados resumidos em NDJSON](phase-7-results.ndjson). Logs completos e
arquivos desta execução ficaram em /tmp/omunculus-real-56ddc4b9023f; são
artefatos locais temporários, não dependências de reprodução.

## Contratos de execução

A suíte completa passou com **280 testes, zero falhas**; compilação com
`--warnings-as-errors` passou. Testes cobrem entrega de escritor externo ao Runtime vivo, resposta de
permissão sem reinício, detach seguido de resultado no inbox, recuperação
de comando pendente com revalidação, rejeição tardia e replay, além da
matriz fake de vinte combinações da fase 6.

O executor usa EVENTS como transporte. Sidecars de lock/readiness/log não
armazenam tarefas. Reinício registra falha de Run interrompida e pedido de
inspeção; eventual repetição exige task.resumed explícito.

A superfície portable usage foi verificada com usage lint; spike foi removido.
Propostas adicionais de CLI, como policy grant, não são anunciadas como
implementadas: concessão permanente usa inbox reply --grant --permanent.

## CLI compilada em processos separados

`mix escript.build` passou. `python3 scripts/validate_cli.py` confirmou
`send --detach` retornando e deixando resultado 3 no inbox; outro processo
apendou uma tarefa por `emit`, que concluiu com resultado 4 no mesmo
executor. `events follow` observou 17 novos eventos, ordenados e sem
duplicatas. O script encerrou o executor temporário criado pelo teste.
