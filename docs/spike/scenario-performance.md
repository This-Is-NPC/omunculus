# Desempenho por cenário, profundidade e ferramentas

Relatório sobre as 28 execuções de 2026-09-07: 12 cloud, 12 Qwen 9B e quatro
repetições cloud. Esta análise releu os EVENTS existentes; não fez novas
chamadas aos modelos nem alterou prompts, políticas ou runtime.

**A raiz não tinha ferramentas de execução nos cenários medium e complex.**
Na contagem, tinha somente delegate. Na escrita, delegate e descoberta.
A permissão para executar diretamente aparece no **concierge intermediário
(depth 1) da complex**, e não em todos os concierges. A explicação anterior
sobre “concierges com ferramentas para trabalhar” precisa dessa delimitação.

## 1. Cenários e ferramentas

Depth é índice a partir de zero: simple tem um nível (0), medium dois
(0 → 1), complex três (0 → 1 → 2). Uma continuação abre outra Run no mesmo
depth; não acrescenta um nível à hierarquia.

As listas abaixo foram conferidas em run.started.tools. O perfil selecionado
estreita a policy por depth e workspace; ler apenas policy.depth.0 no TOML
não basta para saber quais ferramentas chegaram à Run.

Para manter a tabela legível:
- **FS** = read, edit, write, grep, find, ls.
- **Descoberta** = directory, workspaces.
- Listas indicam granted, não permissões negociáveis.

| Cenário / tarefa | Depth 0 | Depth 1 | Depth 2 |
| --- | --- | --- | --- |
| simple / contar | counter; execução direta | não existe | não existe |
| simple / README | FS + counter + descoberta; sem delegate | não existe | não existe |
| medium / contar | **somente delegate** | **somente counter** | não existe |
| medium / README | delegate + descoberta; **sem FS** | FS + counter + descoberta + request_work; sem delegate | não existe |
| complex / contar | **somente delegate** | **counter + delegate** | somente counter |
| complex / README | delegate + descoberta; **sem FS** | **FS + counter + descoberta + delegate** | FS + counter + descoberta + request_work; sem delegate (previsto, não alcançado) |

Em complex/README, request_work está em negotiable nos depths 0 e 1,
e pode haver schema request_permission; isso não concede escrita à raiz.
Nenhuma das bandas human observadas no workspace app estava preenchida.
O workspace infra da fixture complex tem outra política, mas estas tarefas
foram dirigidas a app: não são um teste de escrita com aprovação humana em infra.

O depth 2 de complex/README não foi iniciado nos 28 casos. Sua linha na tabela
foi calculada por Policy.line a partir da fixture; as demais linhas têm
evidência de Runs iniciadas. As bandas granted coincidem nas variantes com
e sem lane para o mesmo cenário, tarefa e depth.

Fontes de configuração: [simple](../../test/fixtures/config/simple.toml),
[medium](../../test/fixtures/config/medium.toml),
[complex](../../test/fixtures/config/complex.toml) e
[lane](../../test/fixtures/config/lane.toml).

## 2. O que conta como sucesso

**Funcional:** a tarefa raiz encerrou e ocorreram dez chamadas counter
concluídas, ou foi criado README.md no workspace. Arquivo existente com
tarefa ainda pendente não passa. O conteúdo editorial do README não foi avaliado.

**Contrato completo:** sucesso funcional, todos os depths esperados,
Runtime sem Runs ativas ao coletar o resultado, replay idêntico e auditoria
causal sem erros. A ausência de depth 2 pode reprovar este critério mesmo
quando uma ferramenta permitida produziu o resultado em depth 1.

**Tentou delegar** significa task.delegated no log. **Filho iniciou** exige
run.started de uma Run filha. A lane pode rejeitar um pedido depois do
append; são medidas diferentes.

## 3. Visão por topologia — matriz inicial

Cada linha reúne contar e README, com e sem lane (quatro casos).
As quatro repetições cloud aparecem separadamente na seção 6.

| Provider | Cenário | Sucesso funcional | Contrato completo | Raiz tentou delegar | Filho iniciou |
| --- | --- | --- | --- | --- | --- |
| DeepSeek cloud | simple | 4/4 | 4/4 | não se aplica | não se aplica |
| DeepSeek cloud | medium | 3/4 | 3/4 | 4/4 | 4/4 |
| DeepSeek cloud | complex | 4/4 | 1/4 | 4/4 | 4/4 |
| Qwen 9B | simple | 2/4 | 2/4 | não se aplica | não se aplica |
| Qwen 9B | medium | 1/4 | 1/4 | 3/4 | 3/4 |
| Qwen 9B | complex | 0/4 | 0/4 | 2/4 | 1/4 |

**Leitura:** cloud delegou da raiz em todos os oito casos que pediam
orquestração. Sua principal perda de hierarquia ocorreu depois, em depth 1
da complex. No local, há falhas antes da primeira delegação, depois dela
e uma tentativa bloqueada pela lane.

## 4. Resultado de cada execução

Tempos são segundos decorridos até conclusão ou limite, incluindo coleta.
Chamadas são chamadas ao modelo concluídas e registradas; timeouts HTTP
podem não gerar model.call.completed. Não representam quantidade de tool calls.
Por exemplo, o cloud executou dez incrementos em apenas duas chamadas ao
modelo no simple/contar sem lane; o local fez nove incrementos em 14 chamadas.

“Efeito em” registra onde houve counter/write concluído, mesmo que a tarefa
tenha estourado o prazo. “F/C” = sucesso funcional / contrato completo.

### DeepSeek cloud

| Cenário / tarefa | Lane | Tempo (s) | Chamadas modelo | Depths iniciados | Efeito em | F/C | Encerramento |
| --- | --- | ---: | ---: | --- | --- | --- | --- |
| simple / count | não | 17.3 | 2 | 0 | 0 | sim/sim | concluído |
| simple / count | sim | 12.3 | 3 | 0 | 0 | sim/sim | concluído |
| simple / write | não | 59.7 | 8 | 0 | 0 | sim/sim | concluído |
| simple / write | sim | 88.7 | 13 | 0 | 0 | sim/sim | concluído |
| medium / count | não | 12.3 | 4 | 0,1 | 1 | sim/sim | concluído |
| medium / count | sim | 19.8 | 4 | 0,1 | 1 | sim/sim | concluído |
| medium / write | não | 181.1 | 18 | 0,1 | 1 | não/não | timeout |
| medium / write | sim | 139.2 | 11 | 0,1 | 1 | sim/sim | concluído |
| complex / count | não | 15.3 | 4 | 0,1 | 1 | sim/não | concluído |
| complex / count | sim | 39.5 | 7 | 0,1,2 | 2 | sim/sim | concluído |
| complex / write | não | 48.3 | 15 | 0,1 | 1 | sim/não | concluído |
| complex / write | sim | 78.9 | 16 | 0,1 | 1 | sim/não | concluído |

### Qwen 9B local

| Cenário / tarefa | Lane | Tempo (s) | Chamadas modelo | Depths iniciados | Efeito em | F/C | Encerramento |
| --- | --- | ---: | ---: | --- | --- | --- | --- |
| simple / count | não | 181.3 | 14 | 0 | 0 | não/não | timeout |
| simple / count | sim | 96.4 | 15 | 0 | 0 | sim/sim | concluído |
| simple / write | não | 38.4 | 1 | 0 | nenhum | não/não | texto final |
| simple / write | sim | 54.5 | 2 | 0 | 0 | sim/sim | concluído |
| medium / count | não | 115.0 | 15 | 0,1 | 1 | sim/sim | concluído |
| medium / count | sim | 12.1 | 1 | 0 | nenhum | não/não | texto final |
| medium / write | não | 180.0 | 1 | 0,1 | nenhum | não/não | timeout |
| medium / write | sim | 181.2 | 2 | 0,1 | nenhum | não/não | timeout |
| complex / count | não | 8.3 | 1 | 0 | nenhum | não/não | texto final |
| complex / count | sim | 10.4 | 1 | 0 | nenhum | não/não | texto final |
| complex / write | não | 180.0 | 5 | 0,1 | nenhum | não/não | timeout |
| complex / write | sim | 27.2 | 2 | 0 | nenhum | não/não | texto final |

## 5. Diagnóstico por cenário

### Simple: execução direta; não há concierge de delegação

Cloud passou nos quatro casos. No local, contar sem lane atingiu o limite
com nove incrementos; contar com lane concluiu dez em 96,4 s. README sem lane
terminou pedindo informações, sem ferramenta; com lane escreveu o arquivo.

Portanto, essas falhas locais não podem ser explicadas por um problema
de hierarquia: não havia filho a delegar.

### Medium: raiz restrita, worker executor

Na contagem, a separação é forte: raiz somente delegate, worker somente
counter. Cloud cumpriu a cadeia nos dois casos. Local cumpriu sem lane;
com lane, a raiz respondeu em texto sem chamar delegate. Ela **não executou
counter indevidamente** — sequer tinha essa ferramenta.

Na escrita, ambas as raízes delegaram nos quatro casos (dois por provider).
A raiz não tinha FS. Cloud sem lane escreveu no worker, mas não concluiu a
tarefa no prazo; registrou 18 chamadas de modelo concluídas e sete erros
de ferramenta no worker. Com lane concluiu em 139,2 s.

No local, ambos os casos atingiram o limite. Sem lane, há timeout HTTP do
worker; com lane, o worker terminou sem usar ferramentas e a raiz abriu uma
continuação, mas não finalizou dentro do limite. Esses problemas ocorreram
**após delegação**, não por ausência de delegate na raiz.

### Complex: raiz restrita, intermediário também pode executar

Na contagem, a raiz só tem delegate. O intermediário tem counter e delegate.
Cloud sem lane contou no intermediário; com lane delegou ao worker:
duas delegações e duas continuações, com counter exclusivamente em depth 2.

Nos dois READMEs cloud, write ocorreu em depth 1 e não houve worker em depth 2.
Isso respeita granted do intermediário, mas descumpre a cadeia esperada
pela matriz. É uma distinção entre autoridade de ferramenta e papel de
orquestração, não evidência de escape de permissão.

No local, as duas contagens encerraram em texto na raiz, sem ferramentas.
README sem lane delegou a technical_writer no depth 1 e depois houve
timeout HTTP. README com lane tentou delegar a dev-docs-writer sem indicar
team. O TeamGate rejeitou task.delegated com **agent without team**;
nenhuma Run filha iniciou. A raiz então pediu detalhes em texto.

Esse último caso é evidência direta de uma intervenção da lane. Não é correto
classificá-lo simplesmente como “o modelo não tentou delegar”.

### Identidade de agente também variou dentro do mesmo depth

O parâmetro agent explícito tem precedência na seleção; team também pode
selecionar seu lead antes do papel padrão por depth. Foram observados:

| Caso | Papel padrão esperado | Identidade iniciada |
| --- | --- | --- |
| Cloud medium/README sem lane, depth 1 | worker | README |
| Local medium/count sem lane, depth 1 | worker | contador_numeros |
| Local complex/README sem lane, depth 1 | repo-concierge | technical_writer |
| Cloud complex/README com lane, depth 1 | repo-concierge | concierge, após team=app |

Os nomes README, contador_numeros e technical_writer não têm entrada de
prompt nas respectivas fixtures. Runtime.Agents usa o prompt genérico quando
não encontra a entrada. Isso é um fator de configuração do harness a isolar;
não demonstra, sozinho, a causa de sucesso ou falha. O caso contador_numeros,
por exemplo, concluiu.

Fontes: [seleção de agente](../../lib/omunculus/chat/scripts.ex),
[resolução de prompt](../../lib/omunculus/runtime/agents.ex) e
[TeamGate](../../lib/omunculus/interceptors/team_gate.ex).

## 6. Repetição da contagem complexa cloud

Somando a matriz inicial e duas rodadas adicionais: seis amostras.
Cinco produziram dez incrementos e somente três cumpriram a cadeia completa.

| Amostra | Lane | Depths | Onde contou | F/C |
| --- | --- | --- | --- | --- |
| inicial | não | 0,1 | 1 | sim/não |
| inicial | sim | 0,1,2 | 2 | sim/sim |
| adicional 1 | não | 0,1 | 1 | sim/não |
| adicional 1 | sim | 0,1,2 | 2 | sim/sim |
| adicional 2 | não | 0,1,2 | 2 | sim/sim |
| adicional 2 | sim | 0 | nenhum | não/não |

A última amostra respondeu em texto na raiz, apesar de ela só ter delegate.
Ter apenas delegate impede contar por ferramenta na raiz, mas **não obriga
o modelo a chamar uma ferramenta antes de responder**. Nas amostras que
contaram em depth 1, a situação é diferente: counter estava concedido ali.

## 7. Limites e próximos experimentos

A amostra inicial tem apenas uma execução por combinação de tarefa/lane.
Não permite estimar uma taxa estável nem atribuir toda diferença à lane.
A rejeição agent without team é um caso causal identificável; nos outros,
também há variabilidade do provider, escolha de agente e orçamento de tempo.

O limite de tarefa foi 180 s; o HTTP, 120 s. Foram quatro timeouts de tarefa
no local e um no cloud. Durações desses casos são observações censuradas,
não tempos de conclusão. Matrizes distintas rodaram simultaneamente em
serviços diferentes; estes números não são benchmark controlado de hardware.

Todos os 28 snapshots de replay coincidiram; não foram encontrados vínculos
causais ausentes ou pais em depth incorreto. Erros de filesystem e a rejeição
de delegação são eventos separados dessas invariantes.

Experimentos que isolam as causas, sem reescrever esta referência:
1. **Medium/count:** repetir a raiz somente delegate; medir chamada de
   delegate antes de texto final e sucesso do worker separadamente.
2. **Complex/count:** fixar o agente esperado por depth e comparar o
   intermediário atual (counter + delegate) com um intermediário apenas
   de delegação, se esse for o contrato confirmado no plano.
3. **Roteamento:** separar alvo válido de agent sem team; classificar
   rejeição esperada como barreira funcionando, não falha do provider.
4. **Escrita local:** aumentar o orçamento em uma campanha separada,
   definir o artefato esperado com clareza e medir worker e continuação.

## Evidência consultável

- [CSV por execução](scenario-performance-cases.csv): comparação em planilha.
- [JSON por depth](scenario-performance-data.json): agentes, bandas, ferramentas
  usadas, Runs, continuações, chamadas de modelo, alvos e rejeições.
- [Comparação original de providers](provider-comparison.md).
- Bancos originais: /tmp/omunculus-real-c27e65311811 (cloud),
  /tmp/omunculus-real-9a77f4818edb (local) e
  /tmp/omunculus-real-410abb4d73ff (repetições cloud).

O JSON e o CSV preservam os dados usados neste relatório mesmo depois que
os bancos temporários forem removidos. Não contêm credenciais nem conversas
completas.
