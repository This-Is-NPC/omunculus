# Qwen: depth 0, 1 e 2, com e sem interceptor de resumo

Campanha de 9 de setembro de 2026 (UTC), `qwen3.5:9b`, preset local e harness
`0569de1`. Resultados e evidências por evento estão em
[qwen-interception-depth-validation.json](qwen-interception-depth-validation.json).
As sessões completas permanecem em `test/sessions.sqlite3`.

## Método

Uma execução independente por célula, em série no mesmo provider local; seis
combinações de depth máximo 0/1/2 e interceptor de resumo desativado/ativado.
Workflow `plain`, sem gate de estágios, para restringir a comparação às dimensões
solicitadas. A tarefa exige um único contador com três chamadas e retornos
`[1, 2, 3]`; com delegação, somente o worker no depth final executa e cada pai
avalia. Depth 0 usa worker diretamente. Os demais usam concierge nos níveis
intermediários e worker no final.

A configuração deriva de `test/fixtures/config/medium.toml`. Ambos os braços
incluem a mesma definição de `handoff-editor`; apenas `enabled` muda entre off/on.
O interceptor é o exemplo `examples/interception-agent.toml`: recebe eventos
`run.completed` com `outcome=reported`, processa o evento completo, incluindo o
checkpoint, e vincula seu resumo a `comment` e `report.comment`. Ele não altera
`report.completed` da tarefa original. O mesmo Qwen executa todos os papéis.

`off` significa desativar esse ator de resumo, não remover as políticas nativas.
Os eventos de Run continuam registrados. O ator não intercepta suas próprias
Runs. Depth 0 testa o resumo no encerramento; depths 1/2 também podem testar
contexto entre filho e pai, quando a execução alcança essa fronteira.

Não há deadline de aprovação/reprovação. O observador encerra ao receber a
conclusão do Work Item raiz ou uma solicitação de intervenção humana, inclusive
`interception.requested` para `actor=human`. Escalada significa tarefa pendente,
não falha técnica nem timeout. Duração é apenas métrica. O encerramento das Runs,
limites de recuperação e reconstrução das projeções são verificados separadamente
do resultado da tarefa. A oracle mede efeitos; não decide pelo pai no harness.

O fingerprint de todos os arquivos `lib/**/*.ex`, ordenados e concatenados com
seus caminhos, permaneceu
`2b8f5e7597cf9600b60f50ceba835d456a94556055ddc9741ebaa709e5089b9f`.
Nenhuma correção do runtime foi aplicada durante a campanha.

Uma tentativa de infraestrutura, `session-fd272eb4a61b2449`, foi excluída: o sandbox
bloqueou a conexão com `EPERM`, antes de qualquer resposta do modelo. A exportação
inicial também revelou um erro de serialização do runner, corrigido antes da
primeira amostra válida. Os seis resultados abaixo usam acesso autorizado ao
serviço local.

## Resultados

| Depth | Resumo | Resultado | Retornos reais | Runs tarefa / ator | Recuperações tarefa / ator | Duração |
|---|---|---|---|---|---|---|
| 0 | off | Concluída | `[1, 2, 3]` | 1 / 0 | 0 / 0 | 0m26s |
| 0 | on | Concluída | `[1, 2, 3]` | 1 / 2 | 1 / 1 | 1m16s |
| 1 | off | Aguardando humano | `[1, 2, 3, 4, 5, 6]` | 3 / 0 | 2 / 0 | 4m00s |
| 1 | on | Aguardando humano | `[1, 2, 3, 1]` | 4 / 5 | 4 / 2 | 5m15s |
| 2 | off | Aguardando humano | `[1, 1, 1]` | 9 / 0 | 2 / 0 | 2m15s |
| 2 | on | Aguardando humano | `[]` | 2 / 4 | 3 / 2 | 3m50s |

As recuperações da tabela são eventos `task.recovery_used`. As novas tentativas
da interação externa são contadas separadamente: no depth 0/on houve 2 pedidos
ao agente e 1 resolução; em 1/on, 3 pedidos ao agente, 1 resolução e 1 escalada
humana; em 2/on, 2 pedidos ao agente, nenhuma resolução e 1 escalada humana.
`actor_requests` no JSON inclui também os pedidos ao humano.

**31 Runs encerradas**, 20 da tarefa e 11 do ator; 59 respostas do modelo.
Todos os seis casos respeitaram o orçamento por Work Item/estágio e preservaram
as projeções após rebuild. Nove das 19 chamadas reais ao contador continham
argumentos proibidos e foram executadas. Só os dois casos depth 0 satisfizeram
conclusão, efeitos, topologia e argumentos válidos.

| Depth | Resumo | Session ID |
|---|---|---|
| 0 | off | `session-18c51cd2cdf766ad` |
| 0 | on | `session-a92d82fc7f91ea4f` |
| 1 | off | `session-f932be26d52b4415` |
| 1 | on | `session-54b7af8e7034f273` |
| 2 | off | `session-c03c4b937b1dba28` |
| 2 | on | `session-7b69cc482dd03e8f` |

### Evidências por cenário

- **0/off:** três chamadas `{}`, retornos `[1,2,3]`, conclusão direta sem recuperação.
- **0/on:** o worker precisou corrigir o formato do relatório. O primeiro ator
  afirmou haver só duas chamadas, apesar de receber os três resultados e o
  checkpoint `calls=3,value=3`. Marcou `completed=false`; a tentativa seguinte
  produziu o resumo correto. A resolução 2579 antecedeu a conclusão da tarefa
  e seu comentário virou o resultado final. Não houve repetição do contador.
- **1/off:** o filho recebeu a instrução de três incrementos, inventou `amount`
  e executou seis chamadas. Houve recuperação de formato; durante a avaliação,
  uma nova delegação foi rejeitada por time inexistente. O orçamento de
  recuperação se esgotou e o fluxo escalou ao humano.
- **1/on:** o primeiro filho retornou `[1,2,3]`, mas duas chamadas tinham
  `parameters` proibido. A resolução 2685 antecedeu a avaliação 2688; o primeiro
  pedido ao modelo do pai continha o resumo e o estado confirmado do contador.
  Mesmo assim, o pai delegou nova execução em 2693. Outro contador retornou `1`.
  O segundo filho relatou incompletude. Os atores confundiram a conclusão do
  resumo com a conclusão dessa tarefa e retornaram `completed=false`, até
  escalar a interação ao humano em 2740. Todas as Runs estavam fechadas.
- **2/off:** já na primeira delegação, evento 2749, o concierge reduziu a tarefa
  de três incrementos para uma chamada. O intermediário abriu três filhos
  distintos, cada um cumprindo essa instrução e retornando `1`. O orçamento
  impediu novas delegações; o break percorreu os pais até o humano.
- **2/on:** a raiz recuperou uma delegação com time inexistente. No nível
  intermediário, três tentativas voltaram a inventar times e foram rejeitadas.
  Nenhum worker de depth 2 chegou a executar. Os atores resumiram os erros,
  mas marcaram `completed=false` por causa da tarefa original; suas quatro
  Runs terminaram e a interação escalou ao humano em 2898.

### O que os dados permitem atribuir

O **defeito determinístico do harness** é aceitar argumentos que contradizem
o schema exposto: `Counter.call/2` ignora os argumentos, e o caminho até a
execução não os rejeitou. Os nove eventos incorretos estão identificados no JSON.
Isso deve ser corrigido antes de usar novas taxas de conclusão como evidência
de conformidade do protocolo.

As respostas recebidas do **Qwen local** também apresentaram erros sem perda de
contexto demonstrada: falsa contagem pelo ator, nova delegação diante de prova
explícita de conclusão e confusão entre resumir um trabalho e executá-lo. No
depth 2/off, a alteração da instrução ocorreu na própria saída do concierge.
Essas decisões semânticas pertencem aos agentes; não são regras que o harness
deva transformar em aprovação automática.

O transporte por eventos entregou o único resumo que chegou a uma avaliação
parental nesta campanha, sem iniciar aquela avaliação antes da resolução. Os
dois resumos aceitos preservaram o comentário original no evento persistido.
As duas outras fronteiras pendentes chegaram ao humano de forma limitada pelo
orçamento. Isso valida esses caminhos observados, não todos os casos de
concorrência, recuperação ou atores externos.

O próximo diagnóstico controlado deve rejeitar argumentos inválidos antes de
efeitos e reapresentar os mesmos eventos/checkpoints aos papéis de resumo e
avaliação. Assim é possível medir preservação de contexto e decisão com a mesma
evidência, sem confundir divergências anteriores da delegação com efeito do
interceptor. Isso não foi implementado nesta campanha.

## Interpretação e limites

`all_runs_closed`, `recovery_bounded` e `replay_equal` não comprovam que o trabalho
foi executado corretamente. `approvals_valid` verifica ligação causal com um
relatório booleano, não a qualidade da decisão do pai. `schemas_match` compara
nomes das tools expostas, não valida seus argumentos. A auditoria adicional
confronta os argumentos do contador com seu schema vazio e
`additionalProperties=false`.

Uma amostra por célula não estima confiabilidade nem comprova que ativar o
interceptor melhora ou piora o resultado. As trajetórias já divergem antes da
primeira interceptação. Temperatura, amostragem, backend, quantização e cache não
foram isolados. A atribuição observável é à resposta recebida do stack Qwen local
sob estes prompts, não exclusivamente aos pesos do modelo.

O fixture e seus critérios foram mantidos: o perfil `count` diz usar somente o
contador, enquanto a instrução raiz nos depths positivos exige delegar. A
interpretação esperada é aplicar essa restrição ao executor final; essa formulação
é uma possível ambiguidade de contexto, não um controle isolado de prompt. Nenhum
prompt foi ajustado entre os braços para favorecer um resultado.

## Reprodução

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml plain --depth 0 --interceptor off --db test/sessions.sqlite3
```

Variar `--depth` entre `0`, `1`, `2` e `--interceptor` entre `off`, `on`.
Cada execução imprime o ID da sessão e o diretório de evidências com
`result.json` e `events.json`. `--repeats N` permite novas amostras. Para analisar
uma sessão existente:

```sh
./omunculus session replay SESSION_ID --db test/sessions.sqlite3 --ui narrative
```

Validação do observador e auditoria de handoffs:

```sh
mise exec -- mix test test/omunculus/workflow_observer_test.exs test/omunculus/workflow_audit_test.exs
```

Resultado: **4 testes, 0 falhas**.
