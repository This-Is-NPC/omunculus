# Validação do harness atual

Campanha iniciada em 2026-09-08 após `e959485`. Objetivo: testar contratos de
orquestração sob providers reais, sem classificar duração como sucesso/falha.

## Método previamente definido

- Banco compartilhado `test/sessions.sqlite3`, seleção por Session ID; filesystem
  e contexto de cada caso isolados. Nenhuma execução depende do resultado de outra.
- DeepSeek primeiro, Qwen 9B depois. Dois casos: sem workflow e com implementação
  seguida de review; duas repetições por caso e por depth máximo (1 e 2).
- Nos casos depth 2, pais têm somente delegate e o worker final tem counter.
  A cadeia exigida é 0 → 1 → 2; depth 1 exige 0 → 1. A política torna a topologia
  explícita. O workflow é atribuído ao worker final.
- Efeito esperado: exatamente `[1,2,3]`, em um único Work Item no depth final;
  raiz concluída após aprovação causal. O oráculo mede efeitos, não decide pelo pai.
- Término observado: conclusão da raiz ou pedido de intervenção humana.
  Duração é métrica; não há deadline global. Falhas de infraestrutura são
  reportadas separadamente, sem atribuí-las ao modelo.
- Verificar fechamento das Runs, snapshots de tools, links pai/filho,
  aprovações/avanços, resultados por rodada e igualdade das projeções após replay.
- Testes controlados existentes cobrem recuperação, rejeições, permissões,
  concorrência e reinício; a campanha real de contagem não substitui esses testes
  nem certifica tarefas arbitrárias de software.

Duas repetições detectam divergências, mas não estimam confiabilidade. Caso um
provider esteja indisponível, registrar o impedimento sem simular suas respostas.

## Contratos controlados e interface

A suíte executada com sockets locais autorizados passou: **335 testes, 0 falhas**.
A execução confinada ao sandbox foi inválida para os testes HTTP (`:eperm`).
O teste temporal de cancelamento que falhara na validação anterior passou nesta
execução; isso não transforma latência em critério de conclusão de tarefa.

Cobertura existente relevante:

| Contrato | Evidência controlada |
| --- | --- |
| Pai decide; filho incompleto recebe comentário e retry | `workflow_test.exs`: child report pending; parent incomplete comment |
| Break/retries persistem e sobem até humano | `workflow_test.exs`: durable retry budget; both responsible levels |
| Falha técnica não repete efeito confirmado automaticamente | `workflow_test.exs`: technical failure breaks |
| Review só executa em sua etapa; aprovação avança uma vez | `workflow_test.exs`: reviewer role; stage approval/restart |
| Avaliação pode delegar e retomar alvo original | `workflow_test.exs`: parent can delegate during assessment |
| Pais não ficam com Run viva esperando filhos | `runtime_test.exs`: waiting root run is not tracked live |
| Sessões concorrentes não cruzam contexto | `multi_session_test.exs` |
| Ferramentas do agente restringem política; selectors inválidos são rejeitados | `agent_contract_test.exs`, `workflow_test.exs` |

Replay pelo executável da sessão nova `session-41ac4c54b3a743f7`, em PTY de
60 colunas: 764 linhas dentro da largura, bordas balanceadas, indicadores e
metadados presentes, resumo de sessão preservado. Nenhum provider é chamado
pelo replay.

## Achado: falso sucesso durante correção do relato

Na sessão Qwen `session-5cfa7bd752f32733` (depth 1, review, repetição 1),
a raiz tentou `agent=counter_worker`, recebeu `agent not in session`, tentou
`delegate` apenas com `agent=""` e recebeu `handoff_comment_required`.
Nenhuma delegação foi aceita; nenhum contador executou; o review não começou.

Depois, o provider devolveu texto com `completed: false`, mas JSON inválido.
O harness solicitou somente correção estrutural, explicitamente proibindo novas
ferramentas/efeitos. Nas respostas seguintes, o conteúdo mudou para afirmações
inventadas de execução, até chegar a JSON válido com `completed=true` e `[1,2,3]`.
O protocolo concluiu a raiz; o oráculo externo identificou zero efeitos.

Isso evidencia deriva semântica no caminho de reparo do relato. O harness não
inventou valores nem repetiu ferramentas, mas o reparo estrutural não preservou
a decisão anterior do agente. Os eventos `model.call.completed` já contêm esses
textos; `Chat.Completions` repassa `choices[0].message.content` e `tool_calls`.
A captura não separa pesos, template e parser do servidor local. Não é evidência
de erro na máquina de estados de review, que nem chegou a executar.

A aprovação semântica continua pertencendo ao agente responsável. Acrescentar
um verificador determinístico de contador ao runtime mascararia esse problema,
em vez de validar o harness. O caso deve orientar um experimento controlado do
reparo de relato, incluindo preservação de intenção e feedback de erro, sem
introduzir aprovação automática de domínio no harness.

As primeiras `messages` e `schemas` recebidas pelo Qwen foram **idênticas**
entre o caso simples da repetição 1 e esse caso com review. Hashes SHA-256 da
serialização JSON com chaves ordenadas: messages
`1b468d1b2816d711f0b297594085be43450b4d9f06dc64189e8fbd50e5e6d9ef`;
schemas `9fde74ce28e9eed7eadc1734d14197d4e6b6212c316bb2d013254bcd35ef95f9`.
O workflow é do worker final; a raiz não tinha essa diferença no prompt inicial.
Logo, a etiqueta “com review” não explica causalmente o erro de delegação.

## Achado: revisão aceita relato sem efeitos

Na segunda repetição Qwen com review em depth 1,
`session-f8599e04da2f288d`, a delegação foi aceita após corrigir um seletor.
O worker relatou `[1,2,3]` sem chamar counter. O pai aprovou, o harness avançou
para review e o reviewer também confirmou os valores alegados sem efeitos
registrados. Logo, gates executados e aprovações causais são necessários, mas
não suficientes para demonstrar qualidade da avaliação dos agentes.

O caso não autoriza mover o julgamento semântico para o runtime. É evidência
para testar o contexto entregue ao avaliador e a distinção explícita entre
relato do filho e observações verificadas. Nesta campanha, a tarefa solicitava
conferir os valores reais; as respostas observadas não sustentaram essa decisão.

## Defeito histórico: delegação incompleta copia a tarefa da raiz

No commit avaliado, `Tools.Delegate.schema/0` exigia `instruction`, mas
`Runtime.Run.delegate/3` usava `args["instruction"] || args[:instruction] || state.instruction`.
Uma chamada sem o argumento obrigatório pode criar um filho com a instrução
inteira da Run pai, em vez de retornar erro de contrato ao modelo.

Na sessão `session-f8599e04da2f288d`, a chamada registrada na sequência 805
continha apenas `agent=""` e `comment`. A sequência 806 criou a delegação
com a instrução da raiz (incluindo a ordem de delegar). O schema efetivamente
enviado exigia `instruction`. Na continuação, a raiz criou outro filho e
ambos percorreram review sem nenhum incremento. A sessão terminou com
`completed=true` e zero efeitos, após 11 Runs e 20 respostas de modelo.

O modelo produziu argumentos inválidos; o harness os aceitou e os transformou
silenciosamente. Essa discrepância é verificável sem julgar a tarefa pelo
runtime. Deve-se exigir o contrato estrutural antes de criar o Work Item;
a avaliação de qualidade continua pertencendo ao pai. A implementação foi
mantida intacta durante a campanha para não misturar versões nos resultados.

O probe histórico, em memória e com respostas controladas, confirmou uma
delegação aceita com apenas comment e cópia da tarefa raiz. Seu script foi
removido após a correção: os testes de regressão agora exigem Work Item e comment.

**Correção conceitual do usuário:** não existe instrução avulsa entre Runs.
O output da delegação é um Work Item filho, acompanhado do comentário. Portanto,
exigir o antigo argumento `instruction` não seria aderir ao TO-BE. A definição
textual fica dentro do Work Item; o harness cria identidade e vínculo com o pai.
Ver [contrato corrigido](../to-be/work-item-handoff.md).

## Achado: nova delegação após efeito já satisfeito

No Qwen depth 2 sem workflow, repetição 1 (`session-0e35e4b1a1697bfd`),
a cadeia alcançou um worker que produziu `[1,2,3]` após retries e avaliação.
Na continuação, a raiz delegou novamente, agora pedindo um incremento.
Outro Work Item executou counter e retornou `1`: a sequência global passou
a `[1,2,3,1]`. Não se trata de um contador chegar a 4, e sim de trabalho
adicional em outro contexto. O oráculo exige exatamente três efeitos num
único Work Item, portanto rejeita essa repetição mesmo se a raiz concluir.

As mensagens system efetivamente registradas nas continuações dos dois casos
Qwen depth 2 da repetição 1 incluem: resultados já aprovados, consolidar evidência,
delegar apenas para requisito não atendido e não repetir efeitos aprovados.
Essa orientação não estava ausente. A captura confirma que foi entregue;
não demonstra que adicionar outra instrução equivalente resolveria a deriva.

Na primeira avaliação de `wi-7bb7d196ff1d501d`, o contexto enviado ao pai
continha literalmente `Execution checkpoint (confirmed tool state): {}`,
além dos comentários do filho alegando `[1,2,3]`. O pai aprovou apesar da
falta de estado confirmado. Assim, nesse caso a diferença entre relato e
checkpoint estava presente no contexto, mas não foi usada adequadamente
na avaliação observada.

No caso Qwen depth 2 com review da repetição 1, após a repetição dos efeitos,
uma chamada HTTP falhou com `Req.TransportError :timeout` (sequências 1404/1405,
`model.call.failed` e `run.failed`). O pai recebeu a falha e tentou novas
delegações com seletores inventados. É timeout de transporte do cliente já
existente, não deadline do cenário. A duplicação dos incrementos precedeu
a falha técnica; o caso não é classificado como incorreto por sua duração.

## Encerramento da campanha e verificação da correção

Foram concluídas 13 das 16 repetições planejadas. A 14ª,
`session-a124de550c7edceb` (Qwen depth 2, workflow, repetição 1), foi interrompida
para corrigir o harness. As duas restantes não foram executadas. A interrupção
não foi convertida em conclusão, falha funcional ou evento terminal inventado.
Os eventos históricos foram preservados em
`test/archive/pre-work-item-handoff.sqlite3`; são evidência da versão antiga.

A correção remove o handoff avulso e registra reservas de recuperação por
Work Item/etapa. Erros de ferramentas/relato, verificação delegada e redelegação
em continuação compartilham o limite; criar outro verificador não o renova.
A suíte posterior passou com **344 testes, zero falhas** (13,2 segundos de
execução da suíte, sem usar isso como critério de sucesso de tarefas reais).
Os testes também preservam o direito do pai de aprovar efeitos existentes em
break e verificam que as etapas seguintes recebem seu próprio orçamento.

Esses resultados demonstram os contratos controlados. Não certificam a qualidade
de decisões do Qwen nem substituem uma nova matriz com modelos reais.

## Smoke real posterior à correção

DeepSeek, sem workflow, depth 1: **concluído com `[1,2,3]`**, um único executor,
4 Runs fechadas, 7 respostas, 2 aprovações causais, zero falhas e zero retries.
Duração observada: 25,159 s (métrica). Session ID:
`session-b7541452ffee3a9b`, no banco ativo `test/sessions.sqlite3`.

O primeiro rebuild comparou também 18 sessões antigas e divergiu: 81 delegações
históricas ainda usavam o campo avulso, removido do projetor. Conforme o pedido
anterior de excluir sessões incompatíveis, foi feita uma cópia SQLite verificada
em `test/archive/pre-work-item-handoff.sqlite3` (1.734 eventos), e essas 18 sessões
foram retiradas do banco ativo. Os 41 eventos do smoke foram preservados sem
alteração. Repetir o rebuild sobre o banco compatível produziu projeções idênticas.
Não houve adaptação de formato antigo no harness.

Os resultados originais, a diferença inicial e a verificação posterior estão
em [evidência estruturada](work-item-handoff-validation.json). A matriz completa
e o Qwen ainda não foram reexecutados após esta correção.
