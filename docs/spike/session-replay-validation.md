# Validação de session replay

Implementação validada em 8 de setembro de 2026, na árvore de trabalho posterior
a `e070ad4`. Não houve avaliação de confiabilidade do modelo nesta entrega.

## Testes determinísticos

`mise exec -- mix test`: **319 testes, zero falhas**, seed `894271`, 13,2 s.
Duração é apenas uma métrica. A suíte inclui:

- Equivalência entre eventos confirmados apresentados ao vivo e replay passivo.
- Rejeições por comentário ausente e agente inexistente, incluindo solicitação
  rejeitada que não chega aos subscribers de execução.
- Input efetivo com schema exigindo comentário, resposta e falha do provider.
- Snapshot de leitura durante append concorrente em WAL, sem seguir novas escritas.
- Banco ausente/inválido, versão não suportada, ausência de criação/migração.
- Retenção com `run --db` e recusa de destino existente.
- Runs intercaladas, redelivery, conteúdo longo, evento sem componente específico
  e ausência de encerramento no prefixo.
- Preservação de banco/projeções e regressões existentes de review, ferramentas,
  retries, break, autorização, retomada e UI direta.

Os testes de efeitos foram ajustados para identificar chamadas de contador:
o histórico agora também registra delegações e ferramentas de controle.
O script de validação real considera somente chamadas de contador com
`outcome=completed` ao medir os efeitos. Rejeições continuam visíveis no log.

## Smoke com provider real

Modelo: `qwen3.5:9b`, servidor local do preset. Pedido: retornar um relato JSON
de conclusão, sem chamar ferramentas. A raiz concluiu com `replay smoke verified`.
Houve uma chamada de modelo, nenhuma chamada de ferramenta e dez eventos.

Banco preservado: `/tmp/omunculus-replay-smoke-local.sqlite3`.
Saída ao vivo: `/tmp/omunculus-replay-smoke.live`.
Replay: `/tmp/omunculus-replay-smoke.replay`.

A comparação das **952 linhas** de apresentação confirmou igualdade do conteúdo,
normalizando somente o cabeçalho Live/Replay e o aviso do caminho do banco.
A resposta do modelo, os prompts e o schema efetivo estão no replay.
Este smoke verifica integração e apresentação; não mede tarefas complexas,
confiabilidade do Qwen ou qualidade de julgamento.

O executável foi gerado com `mise exec -- mix escript.build`. Seu help expõe
`session replay`, e a saída de replay pelo binário foi igual à saída via Mix.

## Limites

Bancos anteriores não ganham conteúdo retroativamente. O comando apresenta seus
eventos atuais e identifica respostas não registradas, sem reconstruir chamadas
a partir de checkpoints. A tabela compacta é um resumo; o detalhe completo do
envelope acompanha a UI sem truncamento de conteúdo. Não há player interativo,
filtro, follow ou retomada pelo replay.
