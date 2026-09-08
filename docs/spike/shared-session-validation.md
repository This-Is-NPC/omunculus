# Banco compartilhado e replay por sessão

Correção implementada na árvore posterior a `df6d031`, em 8 de setembro de 2026.
O banco deixou de identificar implicitamente uma sessão: cada execução registra
seu `session_id`, e o replay exige esse ID.

## Verificações

`mise exec -- mix test`: **323 testes, zero falhas**, seed `433348`, 12,4 s.
Duração é uma métrica, não critério de conclusão de tarefa.

Os testes verificam duas sessões concorrentes no mesmo banco, contagens diferentes,
identidade em todos os eventos da correlação, políticas por sessão, workspaces
homônimos com roots diferentes, detach isolado e reconstrução das projeções.
Também cobrem recuperação que preserva a sessão alheia pendente de humano,
replay por ID sem exibir outra sessão, ID ausente/desconhecido e listagem completa.
`run --db` foi exercitado duas vezes sobre o mesmo banco, conservando ambos os IDs.
Fixtures de send agora registram seus workspaces antes de delegar.

## DeepSeek no banco de testes

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/cloud.toml --db test/sessions.sqlite3
```

Modelo: `deepseek/deepseek-v4-flash-0731`. Uma repetição por cenário, depth 1,
sem prazo de tarefa. As duas execuções encerraram corretamente a raiz.

| Cenário | Session ID | Runs | Efeitos | Review |
| --- | --- | --- | --- | --- |
| Sem etapas | `session-2d5e45b2d398820c` | 4 | `[1,2,3]` | Sem gate |
| Com review | `session-9ad685129cf30be2` | 6 | `[1,2,3]` | Um avanço e duas avaliações |

O banco `test/sessions.sqlite3` contém 41 eventos da primeira sessão e 55 da
segunda. Nenhum evento ficou sem `session_id`. Aprovações e replay das projeções
foram consistentes nos dois casos; não houve falhas de Run ou breaks.
Os [resultados JSON](shared-session-validation.json) preservam os IDs e métricas.

```sh
./omunculus session list --db test/sessions.sqlite3
./omunculus session replay session-9ad685129cf30be2 --db test/sessions.sqlite3
```

O script principal, a matriz real e o diagnóstico de avaliação do pai usam
`test/sessions.sqlite3` por padrão, com opção `--db`. As duas últimas rotinas
foram ajustadas e verificadas sintaticamente; suas campanhas completas não foram
reexecutadas nesta correção. Testes unitários e de integração com fixtures
temporárias continuam isolando seu armazenamento para poder verificar falhas e
criação de bancos sem contaminar as campanhas reais.

O executável foi reconstruído. `session list` retornou os dois IDs, e o replay
da sessão com review imprimiu seus 55 eventos sem incluir o ID da outra sessão
(223.861 bytes de apresentação completa). A saída está em
`/tmp/shared-staged-replay.txt`.

## Limites

Esta entrega não migra os antigos bancos separados nem atribui IDs retroativos
a eventos sem identidade. Os registros históricos originais permanecem intactos.
Os dois cenários DeepSeek acima foram executados novamente no contrato corrigido.
Uma repetição não estima confiabilidade do modelo ou de processos complexos.
