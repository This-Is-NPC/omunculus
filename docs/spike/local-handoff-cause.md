# Investigação causal da escalada local

Sessão: `session-11bc86707117a745`; comparação:
`session-8dd8f423a05a1ac0`. Harness: `3de4653` (runtime da campanha anterior
inalterado). Endpoint confirmado: FastFlowLM 1.0.2, modelo `qwen3.5:9b`.

## Método antes dos probes

Reconstruir os requests registrados, mantendo Work Item, comentário, ferramentas
e modelo. Reemitir requests HTTP isolados sem executar nenhuma ferramenta nem
criar Runs fictícias. Isso testa a preparação do contexto pelo harness, não a
capacidade geral de um modelo. Preservar resposta bruta do provider, incluindo
finish_reason, que o adaptador atual descarta.

- Executor, request 2077: baseline e alteração somente do trecho que exige JSON,
  limitando-o ao relato final e distinguindo tool call de relato; 3 repetições cada.
- Pai, request 2083: baseline; acréscimo de fatos do log ao comentário (zero calls
  do filho e ausência de delegação); remoção somente da mensagem global de
  comentários da sessão; 2 repetições cada.
- Ordem intercalada para reduzir confusão com ordem de execução. Sem mudar
  temperatura, seed ou outros parâmetros ausentes do request original.
- Calls com erro de transporte são inconclusivas. Duração não decide sucesso.
  Amostra pequena: resultado identifica hipóteses e mecanismos, não causalidade
  exclusiva nem confiabilidade estatística. Não alterar prompts de produção aqui.

Segundo bloco, definido após observar os 12 resultados: congelar novamente o
request do pai e comparar baseline, substituição somente da descrição genérica
do agente por sua função nessa avaliação, e mesma função com fatos de execução.
Duas repetições por variante, ordem A/B/C/C/B/A. O restante do system prompt,
Work Item, comment e tools permanece igual. O bloco testa se instrução de agente
genérica atravessando fases compete com a avaliação do alvo.

## Conclusão

A explicação anterior atribuía demais ao modelo. Há uma combinação de preparação
de contexto no harness, decisões incorretas do modelo e limites de observabilidade
do adaptador. O controle de retries funcionou; isso não demonstra que a entrada
fornecida aos agentes esteja adequada para executar e avaliar o trabalho.

### 1. A regra de relato compete com a escolha de ferramentas

`Runtime.Report.instruction/0` começa com “Return only a JSON object containing
completed (boolean) and comment (nonempty string).” A frase é enviada também a
Runs que precisam delegar. Mais abaixo, o mesmo prompt descreve ferramentas de
handoff, sem delimitar explicitamente a primeira regra à resposta final. O pedido
pode ser interpretado como retornar o relato antes de realizar a ação.

No request congelado 2077, o único tool disponível era `delegate`, com
`work_item` e `comment` obrigatórios; `agent` e `team` opcionais. O modelo recebeu
essa ferramenta. A alteração experimental delimitou o JSON ao relato final e
explicou que anunciar uma delegação não chama a ferramenta.

| Request do executor | Respostas | Chamadas delegate válidas | Só relato de intenção |
|---|---:|---:|---:|
| Original | 3 | 1 | 2 |
| Regra de relato delimitada | 3 | 3 | 0 |

Isso sustenta corrigir o escopo do prompt. Não prova que essa frase seja a única
causa: a variante contém tanto a delimitação quanto a distinção explícita entre
chamada e relato; a amostra é pequena e o baseline também conseguiu delegar.
Nenhuma das tools dos probes foi executada.

### 2. A evidência estruturada não chega ao avô

`Workflow.start_assessment/3` apresenta a tarefa, etapa, comentários e apenas
`checkpoint["tool_state"]` do Work Item alvo. Uma Run coordenadora usa delegate,
que não coloca os resultados dos descendentes nesse estado de ferramentas.
Logo, `{}` não distingue um coordenador que não delegou de um coordenador cujo
filho executou corretamente e já foi aprovado.

A comparação dos requests **2083** (caso que escalou) e **2045** (última avaliação
da raiz no caso que passou) confirma que ambos mostram:

```text
Execution checkpoint (confirmed tool state): {}
```

No caso bem-sucedido, os valores reais 1, 2 e 3 existem nos eventos do executor
final, mas não aparecem como resultados estruturados nessa entrada do avô. Ele
recebe frases como “all three increments executed and verified”, sem vínculo de
autor/Run/Work Item com cada observação. Com somente `delegate` disponível, também
não há ferramenta exposta para ele consultar esses eventos diretamente.

**É uma lacuna concreta do contexto do harness**, sobretudo porque o cenário pede
que cada pai confira valores reais. O teste atual de aprovações verifica causalidade
e `completed=true`; não verifica que as evidências foram entregues a cada avaliador.
O sucesso do efeito global não certifica esse requisito de entrada do avaliador.
Não se deve transformar isso em um veredito automático de conclusão.

### 3. O pai mistura relato, intenção, papel e evidência

Na primeira avaliação com erro (request 2083), o contexto tinha uma mensagem
separada com comentários globais da sessão e outra com comentários do alvo mais
o último comentário novamente. A última avaliação repetia ainda mais esses textos.
`Runtime.session_comments/2` seleciona somente `kind, body`; `format_session_comments/1`
apresenta todos os relatos como `run: ...`, sem autor, Run ID ou Work Item ID.

O agente genérico continua descrito como concierge que administra e delega, mesmo
em assessment. O contexto específico de fase manda avaliar o alvo, mas o modelo
frequentemente volta a anunciar ações. O pai também não recebe explicitamente o
depth, a identidade e as ferramentas da Run alvo; isso permite confundir a própria
posição com a do filho. Os probes produziram referências erradas a Level 1/2/3.

Resultados dos requests congelados do pai:

| Variante | Respostas | Aprovação indevida | Relato incompleto | Nova tool call |
|---|---:|---:|---:|---:|
| Original (dois blocos) | 4 | 2 | 2 | 0 |
| Acrescentar fatos de execução e schema | 2 | 0 | 2 | 0 |
| Remover só comentários globais | 2 | 1 | 0 | 1 |
| Descrição do agente focada em assessment | 2 | 0 | 2 | 0 |
| Papel de assessment + fatos | 2 | 0 | 2 | 0 |

No request original, não havia tool call ou filho delegado do alvo. Assim, as
aprovações são indevidas para esse fixture; uma resposta chegou a inventar a
sequência 0→1→2→3. As respostas eram JSON válido e o provider encerrou com `stop`:
o formato correto sozinho não protege a decisão semântica.

As variantes com fatos/papel evitaram aprovação nesses poucos probes, mas os
comments ainda anunciaram delegação, confundiram profundidade ou orientaram
execução inadequadamente. Não são uma solução validada. A remoção dos comentários
globais isoladamente tampouco resolveu. Não há base para atribuir uma taxa de
confiabilidade a essas contagens.

### 4. O backend e o adaptador precisam ser distinguidos do modelo

O provider real é FastFlowLM 1.0.2, com `qwen3.5:9b`, formato NPU2 e quantização
Q4_1. `flm check qwen3.5:9b` verificou config, pesos, tokenizer, pesos visuais e
chat template: todos presentes e compatíveis. Isso reduz a hipótese de instalação
incompleta/incompatível; não valida qualidade numérica da conversão ou inferência.

No evento 2069, a resposta entregue pelo provider continha uma chamada válida de
delegate e outra com nome vazio e `{}` como argumentos. O adaptador do harness
repassa `message.tool_calls`; não inventa esse nome. A fronteira provider/parse
produziu um resultado inutilizável, que o runtime rejeitou antes de executá-lo.
Não temos os tokens crus do modelo para separar geração e parser nessa ocorrência.

Há um [relato upstream de chamadas vazias no FastFlowLM](https://github.com/ROCm/FastFlowLM/issues/649),
mas a reprodução publicada usa outra versão/modelos e limita deliberadamente a
saída. É precedente de investigação, não prova da causa deste caso. A
[release 1.0.2](https://github.com/ROCm/FastFlowLM/releases/tag/v1.0.2) exige pesos
atualizados da família Qwen3.5; a checagem local passou.

Além disso, `Chat.Completions.decode/1` conserva content, tool_calls e usage, mas
descarta `finish_reason`. Portanto, o histórico original não permite distinguir
com precisão EOS, limite de geração ou outra terminação para o JSON malformado
final. Os 18 novos probes preservaram o HTTP completo: nenhum erro de transporte,
5 respostas `tool_calls` e 13 `stop`; nenhum `length`. Isso não recupera o metadado
perdido da execução histórica.

Não houve sinal de saturação de contexto naquela sessão: 1.047–1.559 tokens de
entrada por chamada e ocupação KV reportada de no máximo 4,865%. O último caso
parou por break após retries, não por duração ou falha HTTP. O review configurado
no executor final nunca foi alcançado.

## Correções sugeridas, mantendo o protocolo definido

1. Delimitar o JSON ao relato final; deixar explícito que a delegação é uma tool
   call com Work Item e comment. Não obrigar ferramentas em toda Run: avaliações
   podem legitimamente terminar só com um relato.
2. Preparar o contexto conforme a fase real: tarefa de execução e avaliação do
   alvo precisam de instruções distintas, preservando o papel configurado do agente.
3. Entregar ao pai fatos verificáveis no Work Item/comment: identidade e depth da
   Run alvo, ferramentas que estavam disponíveis, calls/erros observados,
   delegações e resultados dos descendentes com origem identificada. Separar isso
   dos comentários do modelo e evitar repetir comentários globais sem autoria.
   Tudo vem dos eventos existentes; não exige nova máquina de estado ou tabela.
4. Registrar finish_reason e validar a estrutura das tool calls na fronteira do
   provider. Isso deve relatar erro técnico, sem corrigir argumentos ou aprovar
   trabalho automaticamente.
5. Repetir os cenários completos com o mesmo Qwen depois dessas correções de
   contexto. Somente então comparar runtime/pesos ou modelo do pai, com o mesmo
   contrato e evidência, para isolar a contribuição restante.

O pai continua julgando se o trabalho foi concluído. O harness deve fornecer os
fatos e aplicar seu protocolo; não determinar semanticamente que “zero tools =
trabalho incompleto” em tarefas arbitrárias. Nenhuma alteração foi feita ao runtime,
aos presets ou aos prompts de produção durante esta análise.

## Artefatos e reprodução

- [Resumo estruturado](local-handoff-cause.json), incluindo ambiente, contagens e limitações.
- [12 probes de contexto](local-context-probes.jsonl): request e resposta HTTP completos.
- [6 probes de papel do pai](local-parent-role-probes.jsonl): request e resposta HTTP completos.
- Script: `scripts/probe_work_item_context.py`.
- Eventos originais: `test/sessions.sqlite3`, sem alterações pela análise.

```sh
python scripts/probe_work_item_context.py --executor-request 2077 --parent-request 2083 --output /tmp/context-probes.jsonl
python scripts/probe_work_item_context.py --executor-request 2077 --parent-request 2083 --suite parent-role --output /tmp/parent-role-probes.jsonl
```

O script recusa sobrescrever o arquivo de saída. As sequências identificam os
requests nesse banco; os artefatos registram também event_id e hash do request.
