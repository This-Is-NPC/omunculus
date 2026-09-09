# Qwen com os novos agentes: depth 1 e interceptor

Sessão `session-b57ee94335006117`, em `test/sessions.sqlite3`. Provider local
`qwen3.5:9b`, harness `1f925f1`, uma execução em 2026-09-09 (UTC).
[Evidências e hashes dos agentes](qwen-default-agents-validation.json).

**Resultado: aguardando humano; a tarefa não foi concluída.** O contador inicial
foi executado corretamente, mas o pai criou verificações adicionais e outro
worker repetiu um incremento. O summarizer voltou a confundir conclusão do resumo
com conclusão do trabalho resumido.

## Método

Escolhemos depth 1/plain com interceptor porque a campanha anterior nesse caso
mostrou tanto delegação redundante após evidência suficiente quanto confusão do
ator de resumo. O depth 2/on havia parado antes de chegar ao executor final.

O runner agora importa concierge e worker de `priv/agents/*.md`, sobrescrevendo
os prompts antigos da fixture medium. O exemplo de interceptor usa o default
`summarizer`, com `tools=[]` no TOML. Nenhum frontmatter declara tools. A montagem
efetiva de cada Run foi conferida: concierge recebeu delegate; worker recebeu
counter; summarizer recebeu nenhuma tool. Os **16 pedidos ao modelo** continham
o respectivo prompt padrão atual, verificado contra o corpo Markdown.

Tarefa, perfil count, depth, workflow plain, budgets e condição de encerramento
foram mantidos. Não houve deadline de aprovação/reprovação. A comparação anterior
usava o nome handoff-editor para o ator; agora usa summarizer. O reviewer não foi
usado: não existe gate review neste cenário, e as delegações omitiram `agent`,
selecionando worker pelo roteamento padrão. Nenhuma correção de execução de tools
foi aplicada nesta reavaliação.

## Comparação observada

| Medida | Antes: session-54b7af8e7034f273 | Agora |
|---|---|---|
| Desfecho | Aguardando humano | Aguardando humano |
| Valores reais, em ordem | [1,2,3,1] | [1,2,3,1] |
| Argumentos proibidos do contador | 3 de 4 | 0 de 4 |
| Runs da tarefa / ator | 4 / 5 | 6 / 6 |
| Delegações aceitas | 2 | 3 |
| Recuperações de Work Item | 6 | 4 |
| Resoluções do interceptor | 1 | 2 |
| Respostas do modelo | 16 | 16 |
| Duração, apenas métrica | 314.993 ms | 218.855 ms |

Todas as 12 Runs fecharam; as recuperações respeitaram seus limites; o rebuild
preservou as projeções. O efeito adicional aconteceu em outro Work Item, cujo
contador inicia em zero. Não foi o quarto incremento do contador original.

## Sequência causal

1. **2907–2925:** concierge delega; worker executa três chamadas `{}`, retornando
   1, 2 e 3, e informa conclusão.
2. **2935–2939:** o resumo é resolvido e o pai recebe a evidência, incluindo o
   checkpoint `calls=3,value=3`. A entrega por evento ocorreu antes da avaliação.
3. **2941–2943:** apesar de escrever que todos os critérios estavam atendidos,
   o pai chama delegate para “Verify the counter value ...”. Isso cria outro
   Work Item e consome uma recuperação. Seu system prompt já dizia não delegar
   apenas para confirmar um resultado demonstrado.
4. **2949–2959:** o worker de verificação responde sem tools, baseado no comentário
   recebido. O summarizer produz outro resumo concluído. Essa resposta não
   representa uma nova inspeção independente dos efeitos.
5. **2967–2977:** o pai delega mais uma revisão. O novo worker possui counter,
   chama a tool e recebe 1 em seu próprio Work Item. Depois relata uma discrepância
   com o resultado 3 e solicita break. A descrição da tool e o prompt do worker
   já alertavam contra repetir efeitos para verificar trabalho.
6. **2983–3007:** o summarizer produz quatro relatórios com `completed=false`,
   atribuindo a incompletude à tarefa original. Seu prompt recebido continha a
   regra explícita de que resumir uma falha pode ser `completed=true`. As tentativas
   internas e da interação se esgotam; em **3011** a interação solicita humano.

A informação provisória de que o pai teria aprovado sem nova delegação foi
corrigida durante a observação: o texto do comentário reconhecia conclusão,
mas a ação efetiva era delegate. A classificação acima usa os eventos de tools,
não apenas a declaração textual.

## Conclusão e limites

Os prompts novos foram realmente usados; isso não foi uma execução acidental com
os antigos. A amostra eliminou argumentos inválidos, mas não eliminou delegações
redundantes, verificação por mutação nem a confusão do summarizer. Não há evidência
de duplicação espontânea pelo scheduler: os novos efeitos decorreram das tools
solicitadas pelo modelo.

O problema de aceitar argumentos inválidos identificado antes continua existindo
no harness, mas não explica esta amostra, cujos quatro argumentos eram válidos.
A disponibilidade de counter no worker de verificação decorreu do preset e do
roteamento escolhido. Não foi uma tool concedida pelo arquivo Markdown.

Uma amostra não estima confiabilidade nem isola pesos, backend e prompt. Não há
base para declarar que apenas reforçar o texto resolveu o problema. Uma próxima
comparação controlada precisa reapresentar a mesma avaliação e o mesmo evento
incompleto aos agentes, verificando decisão, contexto e tools separadamente.

## Reprodução

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml plain --depth 1 --interceptor on --db test/sessions.sqlite3
./omunculus session replay session-b57ee94335006117 --db test/sessions.sqlite3 --ui narrative
```

Evidências completas exportadas pelo runner em
`/tmp/omunculus-stages-313EA5602B/1-plain/events.json` e `result.json`.
