# Narrative: análise individual de Runs

Status: implementado.

Uma Run é a unidade visual principal. A abertura usa `┌── Run NN · STARTED ───`;
modelo, rodadas e tool calls aparecem dentro dela, com indicadores `├─○` (início),
`├─●` (resultado) e `├─×` (falha). Cada tentativa de ferramenta tem número próprio,
round, argumentos e resultado, associados pela identidade/causação registrada.
Fechar uma chamada não fecha a Run nem aprova seu Work Item.

## Metadados na abertura

Campos alinhados em seções, sem truncar IDs ou comentários:

- Identity: Session ID, Run ID, Work Item ID, todos completos.
- Agent: Name, Kind, Depth, Model.
- Parent: Run ID, Work Item ID, Agent e Model, consultados na Run pai registrada.
- Activation: Started (data, hora e offset), Stage, Reason, Attempt,
  Trigger event ID, Originating Run ID e Max rounds.
- Input comment: comentário de ativação registrado. Para a entrada humana,
  usar o rótulo Initial instruction. Não substituir por objetivo antigo em retry,
  avaliação ou continuação. Mostrar a origem (evento) do comentário.
- Available tools: nomes das ferramentas expostas, incluindo controles. Novas
  execuções fixam essa lista em run.started. As schemas de cada chamada confirmam
  a exposição efetiva; alterações aparecem na rodada. Se não houver snapshot
  inicial, informar a ausência e mostrar a lista quando a primeira chamada chegar.

Usar apenas dados persistidos, sem configuração atual, migração ou atribuição
retroativa. Ausência de valor significa “not recorded”; ausência explícita de pai
significa “none”. Datas mantêm o offset registrado (UTC é mostrado como +00:00).

## Corpo e encerramento

Exibir rodada iniciada, chamadas de modelo e tools individualmente com seus
indicadores. Uma rodada fecha quando a resposta do modelo e todas as tool calls
anunciadas nela tiverem resultado registrado. Não inferir sucesso da tarefa.
Ao final: comentário da Run, resumo e tabela por rodada (model calls, tool calls,
tokens e soma dos tempos registrados). Valores faltantes/parciais são explícitos.

Run summary repete Run ID, Started, Finished, Duration, Outcome, Rounds, Tool calls
e Tokens. Duração da Run é diferença entre início/fim registrados, em h/m/s/ms,
não a soma de chamadas nem o tempo de replay. Rodapé: `Run NN · COMPLETED` ou
`FAILED`, duração e outcome. Sem fechamento, não inventar Finished/duração final:
mostrar OPEN e “not recorded”. Analytics da sessão permanecem ao final.

## Concorrência e leitura ao vivo

Manter a sequência do log e imprimir sem aguardar outras Runs. Se outra Run ou
um evento de coordenação interromper a exibição, fechar apenas o segmento visual
com `DISPLAY PAUSED`, identificando a Run. Ao retornar, abrir `CONTINUED` com os
metadados completos. Isso não é pausa nem retomada da execução. Nunca aninhar
caixas na mesma coluna ou deixar resultados sem cabeçalho. Eventos de coordenação
usam blocos próprios; modelos e ferramentas usam indicadores dentro da Run.

## Validação

Comparar live/replay; testar pai com modelo diferente, comentário de retry distinto
da instrução original, ferramentas de controle e mudanças nas schemas, concorrência
com IDs de tool reutilizados, duração superior a uma hora, dados ausentes, falha,
EOF aberto e largura reduzida. Confirmar metadados, pares de chamadas, indicadores,
tabela e ausência de molduras aninhadas ou conteúdo órfão na sessão gravada.

Novas delegações e request_work também persistem `comment` recebido pela tool no
respectivo evento de coordenação. Essa captura evita atribuir à Run filha a
instrução original de um ancestral quando o comentário não consta da cadeia causal.
Logs existentes sem esse dado continuam mostrando “not recorded”; não são alterados.
