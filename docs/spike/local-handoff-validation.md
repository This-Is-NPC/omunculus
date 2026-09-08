# Revalidação local do contrato entre Runs

Harness avaliado: `075199c`, modelo `qwen3.5:9b`, preset `presets/local.toml`.
Quatro cenários independentes: depth 1 e 2, sem workflow e com implementação/review,
uma repetição por cenário. Duração é métrica; conclusão ou intervenção humana
encerra a observação. Não se altera o harness durante a campanha.

Correção da medição: `task.delegated` é persistido antes dos interceptores.
Uma delegação rejeitada deve criar zero Runs filhas; não pode ser contada como
handoff aceito sem Run correspondente. O indicador anterior `handoffs_valid`
fazia essa contagem incorreta. Separar entregas aceitas e rejeitadas, preservando
os resultados originais para auditoria. Essa alteração não afeta a execução do
modelo, as políticas, os prompts ou o orçamento de retries.

## Resultados

| Cenário | Resultado observado | Efeitos | Runs | Respostas | Recuperações* | Duração |
|---|---|---|---:|---:|---:|---:|
| Depth 1, sem workflow | Concluído e aprovado | `[1,2,3]` | 5 | 9 | 2 | 2m11s |
| Depth 1, implementação/review | Concluído e aprovado | `[1,2,3]` | 6 | 11 | 2 | 1m52s |
| Depth 2, sem workflow | Concluído e aprovado | `[1,2,3]` | 14 | 17 | 4 | 2m47s |
| Depth 2, implementação/review | Break; aguarda humano | Nenhum | 8 | 8 | 3 | 1m41s |

* Soma das reservas na sessão. O limite é **2 por Work Item/etapa**, não por
sessão inteira. No terceiro cenário, raiz/intermediário/executor usaram 1/1/2.
No quarto, raiz/intermediário usaram 1/2. Não houve estouro nem renovação de limite.
As quatro sessões terminaram a observação pelo protocolo; nenhuma foi cortada por
duração. Não há processo de validação ainda rodando.

Em todos os cenários: Runs fechadas, snapshots de ferramentas coerentes com os
schemas, linhagem válida, handoffs aceitos corretos, rejeições sem Run filha e
replay com projeções idênticas. Nos três concluídos, os três efeitos pertencem a
um único Work Item no depth requerido, e as aprovações seguem o relato causal do
responsável. No quarto, não houve aprovação nem execução do gate de review.

## O que aconteceu

- **Depth 1 sem workflow:** Qwen inventou time/agente. A tentativa foi rejeitada.
  Após feedback e retry, delegou corretamente; executor produziu os três valores.
- **Depth 1 com review:** executor e pai produziram relatos fora do formato. Duas
  correções consumiram o mesmo orçamento da etapa `in_progress`. O pai aprovou,
  review executou na etapa seguinte e o trabalho foi concluído sem repetir efeitos.
- **Depth 2 sem workflow:** houve relatos de intenção sem chamada de ferramenta.
  A delegação final pediu inicialmente um incremento. O pai pediu correções no
  mesmo Work Item, preservando o contador entre retries: valores 1, 2 e 3.
  O resultado final respeitou a tarefa global, sem criar novos contadores.
- **Depth 2 com review:** o intermediário anunciou delegação em três Runs, sem
  chamar `delegate`. O pai pediu correções, chegando aos dois retries desse alvo.
  Seu primeiro feedback ainda exigia seletores opcionais e sugeria `Level 2`,
  agravando a confusão de roteamento. A última avaliação trouxe JSON malformado
  com texto que afirmava a delegação e `completed:true`, apesar de nenhum efeito.
  O harness não aceitou esse relato: sem orçamento para repará-lo, emitiu break
  ao humano com o comentário original. A tarefa permanece pendente.

Portanto, o controle de recuperação funcionou nesta amostra, inclusive quando o
modelo insistiu sem executar. **A confiabilidade para concluir todas as tarefas
não está resolvida:** 3 conclusões corretas e 1 intervenção necessária. O texto
incorreto do último pai também mostra risco semântico que não deve ser convertido
em julgamento automático pelo harness. Modelos, prompts e contexto ainda precisam
ser avaliados por sua capacidade de escolher ações e julgar evidências.

O quarto caso falhou em progredir antes de atingir o executor depth 2 e seu review;
isso não demonstra um defeito causado pelo gate. As primeiras mensagens e schemas
da raiz são idênticos entre os dois casos depth 2 (JSON canônico, chaves ordenadas):

- messages SHA-256: `0109ba9ba59adb2836a4d9eb5b5668e10cc281022d455558640c6e633f88d9d2`
- schemas SHA-256: `ac38cf3b6760d07479249b41fc5702b65dfb045a3122887ff49938f7eb651e57`

Uma repetição por cenário não estima confiabilidade nem prova que toda forma de
loop foi eliminada. A campanha anterior teve, por exemplo, 31 Runs e 58 respostas
no depth 2 sem workflow, com efeitos `[1,2,3,1,1,2,1,2,1,1]`; agora foram 14 Runs,
17 respostas e apenas `[1,2,3]`. É comparação descritiva de execuções, não uma taxa
de melhoria atribuível a uma única mudança.

## Evidências e reprodução

Banco ativo: `test/sessions.sqlite3`. Resultados brutos, auditoria corrigida,
reservas por Work Item e erros de ferramentas estão em
[local-handoff-validation.json](local-handoff-validation.json).
A medição corrigida foi aplicada também às duas sessões depth 1, sem rerodar os
modelos nem alterar seus eventos. Seu teste de regressão passou: 1 teste, 0 falhas.

| Cenário | Session ID |
|---|---|
| Depth 1, sem workflow | `session-e169ade71f8d0682` |
| Depth 1, com review | `session-78b9fe71b9fb3c6d` |
| Depth 2, sem workflow | `session-8dd8f423a05a1ac0` |
| Depth 2, com review | `session-11bc86707117a745` |

Para analisar a escalada na UI do CLI (replay executado com sucesso):

```sh
./omunculus session replay session-11bc86707117a745 --db test/sessions.sqlite3 --ui narrative
```

Comandos da campanha:

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml --depth 1 --repeats 1
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml --depth 2 --repeats 1
```
