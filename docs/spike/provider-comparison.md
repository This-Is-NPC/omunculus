Status: validado em 2026-09-07 — 28 casos executados; efeitos e hierarquia discriminados

# Comparação de providers na fase 7

A matriz usa as mesmas fixtures simple, medium e complex, as tarefas
“conte até 10” e “escrever um README”, com e sem lane. Cada caso tem
filesystem e SQLite próprios em /tmp. Os presets selecionam
deepseek/deepseek-v4-flash-0731 no OpenRouter e qwen3.5:9b no FastFlowLM local.
Credenciais são carregadas pelo Dotenv do projeto e mantidas fora dos
artefatos versionados. Nenhuma política ou prompt da fixture foi relaxado.

Para reproduzir:

```sh
mise exec -- mix run scripts/validate_real_matrix.exs --preset presets/cloud.toml
mise exec -- mix run scripts/validate_real_matrix.exs --preset presets/local.toml
```

O script aceita --rounds, --base, --task e --timeout. Defaults: uma rodada,
as três fixtures e 180 segundos por tarefa. O timeout de uma chamada
individual do cliente HTTP permanece 120 segundos.

## Critérios

- Efeito: tarefa concluída e dez chamadas counter concluídas, ou README.md
  existente no workspace. Não é avaliação editorial do conteúdo do README.
- Profundidade: Runs em todos os níveis esperados pela fixture. A presença
  de depth 2 sozinha não substitui a auditoria dos vínculos de parentesco.
- Contrato agregado: efeito, profundidade completa, Runtime sem Runs ativas
  ao fechar o caso, replay com projeções idênticas e auditoria causal sem erros.
- Auditoria adicional: causação existente, pai no depth imediatamente anterior,
  erros de ferramenta e motivos de run.failed.
- O modelo registrado em model.call.completed deve corresponder ao preset.
  Esse campo registra a seleção do cliente, não audita os pesos do servidor.

As matrizes cloud e local podem executar simultaneamente, mas cada uma
serializa seus casos. Tempos são observações desta máquina e destes serviços,
não um benchmark controlado de desempenho entre modelos.

## Referência anterior

A rodada qwen3.5:4b obteve 5/12 efeitos e 12/12 replays idênticos.
Não comprovou a cadeia completa de três níveis. Seus resultados permanecem
em [phase-7-validation.md](phase-7-validation.md); não foram substituídos.

## Cuidados de interpretação

Uma execução com lane e outra sem lane também são amostras diferentes de
um provider não determinístico. Uma diferença de sucesso não comprova que
a lane causou a diferença; é necessário repetir o mesmo cenário.

Timeout com arquivo já escrito permanece falha de conclusão da tarefa.
Texto pedindo esclarecimentos sem criar arquivo não conta como efeito.
Efeito produzido diretamente por um concierge intermediário não comprova
a cadeia de três níveis, mesmo quando a policy permite essa ferramenta.

Os diretórios das fixtures contêm TOML e o SQLite do harness. A exploração
de arquivos inclui esses artefatos; os tempos de escrita também refletem
essa tarefa de documentação pouco especificada.

## Resultado cloud

Matriz inicial: **11/12 sucessos funcionais**, **8/12 contratos agregados**,
**12/12 replays iguais**. O README medium sem lane foi escrito, mas a tarefa
não encerrou no limite de 180 segundos. A contagem complex sem lane e as
duas escritas complex produziram efeito no depth 1, sem acionar depth 2.

Na contagem complex com lane houve duas delegações, duas continuações e
retorno até a raiz. Isso comprova uma execução real da cadeia de três níveis.

Repetição focada:

```sh
mise exec -- mix run scripts/validate_real_matrix.exs --preset presets/cloud.toml \
  --base complex --task count --rounds 2
```

| Rodada adicional | Lane | Efeito | Profundidades | Contrato agregado |
| --- | --- | --- | --- | --- |
| 1 | não | sim | 0, 1 | não |
| 1 | sim | sim | 0, 1, 2 | sim |
| 2 | não | sim | 0, 1, 2 | sim |
| 2 | sim | não | 0 | não |

As quatro repetições produziram 3/4 efeitos, 2/4 contratos agregados e
4/4 replays iguais. No último caso, a raiz contou em texto sem chamar tools.
O repo-concierge recebeu as mesmas bandas granted counter/delegate nas duas
variantes. Seu prompt manda delegar, mas a policy também permite contar
diretamente: a hierarquia depende da aderência ao prompt.

Nos 16 casos cloud não houve referência de causação ausente nem vínculo
pai/filho em profundidade incorreta.
[Resultados cloud auditados](cloud-validation-results.ndjson).

Artefatos locais temporários:
- matriz: /tmp/omunculus-real-c27e65311811;
- repetição: /tmp/omunculus-real-410abb4d73ff.

## Resultado local 9B

Matriz: **3/12 sucessos funcionais**, **3/12 contratos agregados** e
**12/12 replays iguais**. Nenhum caso alcançou depth 2.

Quatro casos atingiram o limite da tarefa: contagem simple sem lane (nove
incrementos), ambas as escritas medium e escrita complex sem lane.
Dois desses casos registraram também timeout HTTP do worker. Outros cinco
encerraram em texto sem o efeito solicitado; no README simple sem lane,
por exemplo, o modelo pediu informações adicionais.

Sucessos: contagem simple com lane, README simple com lane e contagem
medium sem lane. Causação e vínculos de parentesco não apresentaram erros.
[Resultados locais auditados](local-9b-validation-results.ndjson).

Artefatos locais: /tmp/omunculus-real-9a77f4818edb.

## Comparação da matriz inicial

| Caso | Lane | Cloud efeito / contrato | Local 9B efeito / contrato |
| --- | --- | --- | --- |
| simple count | não | sim / sim | não / não |
| simple count | sim | sim / sim | sim / sim |
| simple write | não | sim / sim | não / não |
| simple write | sim | sim / sim | sim / sim |
| medium count | não | sim / sim | sim / sim |
| medium count | sim | sim / sim | não / não |
| medium write | não | não / não | não / não |
| medium write | sim | sim / sim | não / não |
| complex count | não | sim / não | não / não |
| complex count | sim | sim / sim | não / não |
| complex write | não | sim / não | não / não |
| complex write | sim | sim / não | não / não |

## Encaminhamento

O cloud foi a melhor referência funcional nesta matriz e nestes limites de
tempo. Mesmo assim, as repetições demonstram que trocar o modelo não basta
para tornar a hierarquia confiável.

Próximo experimento: isolar a aderência ao contrato com instruções de tarefa
que explicitem ferramenta, artefato e critério de conclusão, preservando
esta baseline. Depois, conferir se o papel de concierge deve permitir
execução direta segundo o plano; não estreitar a policy apenas para obter
uma matriz verde. No local, testar orçamento de tempo maior separadamente,
para distinguir latência de ausência de ação.

As 28 execuções tiveram snapshots de replay iguais e nenhuma referência
causal ou vínculo pai/filho inválido. Em casos com timeout ainda havia
Runs ativas no instante da coleta; eles não passam no contrato agregado.
Nenhuma alteração no runtime foi feita nesta rodada. A suíte de 280 testes
refere-se à implementação anterior; esta rodada validou os providers reais
e o runner de matriz. Formatação e git diff --check também passaram.
