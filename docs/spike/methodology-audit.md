# Auditoria da metodologia da matriz real

Data: 2026-09-07. Escopo: runner, fixtures, resolver de agentes, loop do
Agent e registros das 28 execuções. Esta auditoria não fez chamadas aos
providers reais. O diagnóstico reproduzível está em
[scripts/probe_methodology.exs](../../scripts/probe_methodology.exs).

**Veredito:** a matriz é útil como teste exploratório de integração. Ainda
não é um benchmark controlado de modelos, nem certificação completa de
orquestração. Os resultados registrados permanecem observações válidas,
mas parte da interpretação anterior atribuiu ao modelo comportamentos que
também dependem do harness e da definição do teste.

## O que faz sentido

- Fixtures por topologia, duas tarefas e variantes com/sem interceptors
  correspondem à rodada real de três níveis prevista na fase 7.
- Bancos e filesystems separados evitam reutilizar o resultado de outro caso.
- Conferir tool calls e arquivo é melhor que aceitar apenas a frase “feito”.
- Separar sucesso funcional de hierarquia revelou atalhos em depth 1.
- Registrar falhas, tempos, causação e replay permite investigação posterior.
- As quatro repetições cloud foram reportadas separadamente da matriz inicial.

A rodada real não cobre medium-teams/complex-teams, escrita em infra com
aprovação humana, request_work, reinício ou redelivery. Isso delimita seu
escopo; não é uma exigência adicional inventada para a rodada real da fase 7.
Os testes determinísticos cobrem outros contratos, mas a matriz real sozinha
não valida todo o TO-BE.

## Achados prioritários

### A1 — Alto: o prompt entregue não corresponde a todas as instruções da fixture

simple e medium definem profiles.count.instructions. Runtime.Agents recebe
ctx.profile, mas seu mapa de agente não transporta as instruções desse perfil.
Runtime.Run repassa agent[:instructions], que fica nil. Além disso, quando
system_prompt está definido, Agent escolhe esse texto em vez de compô-lo
com as instruções extras.

O probe carregou a fixture simple e usou o resolver real: a instrução
“Use only the counter tool...” estava no config, mas não no prompt resolvido.
Não é correto dizer que o modelo desobedeceu essa instrução específica sem
confirmar que ela foi enviada.

**Correção metodológica:** salvar e conferir messages/schemas efetivos antes
da campanha. Corrigir a propagação das instruções conforme o plano e abrir
uma nova baseline. Não concatenar cegamente “only counter” na raiz que só
pode delegar: a interação entre instrução do perfil e papel precisa ser
definida por depth.

Fontes: [Runtime.Agents](../../lib/omunculus/runtime/agents.ex),
[Runtime.Run](../../lib/omunculus/runtime/run.ex),
[Agent](../../lib/omunculus/agent.ex).

### A2 — Alto: há ajuda automática desigual para a contagem

Agent.counter_target só ativa quando tools é exatamente ["counter"].
Se o modelo responde em texto antes de atingir o alvo, o harness injeta outra
mensagem de usuário mandando chamar counter e não responder em texto.
Isso não ocorre com ["delegate"] nem ["counter", "delegate"].

Probe com a mesma resposta constante “10”, max_turns=3 e sem tool calls:

| Tools oferecidas | Chamadas ao chat simulado | Mensagens extras de insistência |
| --- | ---: | ---: |
| counter | 3 | 2 |
| delegate | 1 | 0 |
| counter + delegate | 1 | 0 |

Assim, o worker de contagem e o concierge não recebem a mesma assistência.
Diferenças de chamadas, duração e conclusão entre depths não medem somente
capacidade do modelo. O mesmo tratamento entre providers em um cenário
continua útil para comparar o produto completo, mas precisa ser declarado.

**Correção:** separar “modelo sem assistência” de “harness com recuperação”.
Registrar nudges, regra de parada e tentativas. Para testar o produto atual,
manter a ajuda explícita no protocolo; para comparar aderência por papel,
usar uma política de recuperação definida para cada papel.

### A3 — Alto: verificadores de sucesso aceitam resultados insuficientes

O runner soma tool.call.completed de counter no banco inteiro. Dez chamadas
não provam que um contador chegou a 10: dois contadores independentes com
cinco chamadas cada satisfazem a expressão. A tool mantém estado próprio
no contexto de execução.

Para escrita, o verificador usa File.exists?(README.md). O probe confirmou
que tanto um arquivo vazio quanto um diretório com esse nome passam.
Não são provas de que isso ocorreu nos modelos; são contraexemplos à
suficiência dos critérios.

full_depth verifica a presença dos índices 0..max_depth. Mesmo com
parent_run_id válido, isso não exige que a ferramenta produtiva tenha rodado
no worker final, nem que seu resultado tenha sido consumido pelas
continuações até a raiz. Um worker acionado sem realizar o trabalho pode
coexistir com efeito produzido no intermediário.

**Correção:** validar valor final e sequência do contador na linhagem
esperada; arquivo regular, não vazio e conteúdo mínimo definido; ligar a
tool call ao Work Item responsável, sua conclusão, às continuações e ao
resultado da raiz. Declarar required_depth como requisito do cenário;
a existência de uma linha de policy para depth N é um teto, não uma prova
de que toda tarefa deve visitar N.

Fonte: [runner](../../scripts/validate_real_matrix.exs),
[counter](../../lib/omunculus/tools/counter.ex).

### A4 — Alto: mudar depth também muda outras condições do experimento

simple e medium escrevem na raiz temporária que contém config, provider.toml
e o SQLite/WAL do próprio teste. complex escreve em fixtures/app, outra
subpasta, inicialmente vazia. O contexto de arquivos não é equivalente:
a tarefa “escrever um README” pode virar documentação do harness nas duas
primeiras topologias e criação de um documento genérico na terceira.

Também mudam ferramentas, workspaces, automações e prompts. Os alvos agent
ou team escolhidos pelo modelo podem alterar o agente/prompt efetivo.
Nomes fora do catálogo receberam prompt genérico; team=app selecionou outro
concierge em uma execução.

**Correção:** usar o mesmo pequeno projeto de referência em todos os casos,
manter banco/config/log fora dos roots acessíveis ao modelo e fixar papéis
para medir profundidade. Avaliar seleção dinâmica de agentes em uma
campanha própria. Não afirmar que a diferença de tempo é causada pelo depth
quando todo esse conjunto mudou.

### A5 — Alto: o replay é coletado antes de garantir parada dos escritores

O runner espera no máximo cerca de um segundo por Runtime vazio e prossegue
mesmo se ainda houver Runs. Faz snapshot/rebuild no banco vivo; só encerra
o SessionExecutor depois de registrar a linha de resultado. Cinco casos
tinham runtime_idle=false na coleta.

Não encontrei diferença entre a contagem de eventos registrada e o total
final nos 28 bancos examinados. O risco de corrida é do método, não uma
corrupção demonstrada nesta campanha. Além disso, igualdade ao reaplicar o
mesmo reducer demonstra consistência, não correção semântica independente.

**Correção:** capturar um prefixo imutável até sequence S, reconstruí-lo em
outro banco e comparar projeções com asserts de domínio independentes.
Em timeout, registrar o estado interrompido e controlar cancelamento antes
da coleta final. Não usar um atraso fixo como barreira de conclusão.

Fonte: [runner](../../scripts/validate_real_matrix.exs),
[Projector](../../lib/omunculus/event_core/projector.ex).

### A6 — Médio: amostra e controle insuficientes para inferência causal

A matriz inicial tem uma amostra por célula. A ordem é sempre sem lane antes
de com lane. Não há randomização, aquecimento separado ou repetição simétrica
nos dois providers. O cliente não fixa temperature/seed nem registra o backend
específico escolhido pelo serviço cloud. Os limites e defaults também fazem
parte do comportamento medido.

As repetições cloud demonstram variabilidade observada; não estimam uma taxa
estável. Uma tentativa foi efetivamente rejeitada pelo TeamGate, com motivo
explícito no log. Esse efeito da lane é comprovável para aquele pedido;
as demais diferenças de resultado não podem ser atribuídas automaticamente
à lane ou a uma superioridade geral de modelo.

**Correção:** pré-definir repetições por célula, alternar/randomizar a ordem,
registrar versões, parâmetros suportados e requests efetivos, e separar testes positivos
de roteamento de pedidos inválidos que devem ser rejeitados.

### A7 — Médio: tempo limite e métricas misturam capacidade e responsividade

O limite global é 180 s; uma chamada HTTP pode durar até 120 s.
elapsed_ms também inclui sincronização e replay. model.call.completed não
inclui necessariamente chamadas que falharam por timeout. A contagem local
que fez nove incrementos e venceu o prazo não prova incapacidade de contar.

Esse orçamento é válido se o requisito for concluir em três minutos.
Não é suficiente para classificar a falha como incapacidade do modelo.

**Correção:** reportar tempo de modelo, tools, orquestração e validação
separados; tentativas HTTP, erros, tokens e nudges; distinguir resultado
incorreto, resposta sem ação, rejeição esperada, limite de turnos e timeout.
Campanha de responsividade usa orçamento comum; campanha de capacidade usa
outro orçamento explicitamente definido.

## O que podemos manter e o que devemos retirar das conclusões

| Afirmação | Avaliação |
| --- | --- |
| Houve uma cadeia real 0 → 1 → 2 no cloud | Sustentada pelos eventos e tools por depth |
| Cloud teve 11/12 no critério funcional usado; local, 3/12 | Descrição correta daquela campanha e daquele critério |
| Alguns pedidos encerraram em texto sem efeito | Sustentado; não explica sozinho a causa |
| Um pedido inválido foi barrado pelo TeamGate | Sustentado pelo evento de rejeição |
| Os snapshots comparados coincidiram em 28 casos | Observado; não certifica correção independente nem ausência de corridas |
| O modelo é a causa exclusiva da instabilidade | Não sustentada |
| Maior depth causou a piora ou a lane melhorou o modelo | Não sustentada pelo desenho |
| A matriz certifica 100% do plano | Não sustentada |
| Os percentuais são taxas de confiabilidade dos modelos | Não sustentada pelo tamanho/controle da amostra |

## Sequência recomendada para a próxima campanha

1. Definir três avaliações: **correção do runtime** com Fake e entradas
   controladas; **aderência do modelo** com papéis/prompts fixos; **produto
   completo** com suas recuperações, roteamento e orçamento de tempo.
2. Corrigir o contrato de prompt e os verificadores antes de novas comparações.
3. Preparar um projeto de referência e separar seu workspace do harness.
4. Congelar requests/schemas e políticas por cenário; testar explicitamente
   raiz somente delegate, intermediário somente delegate e intermediário
   executor como cenários distintos, respeitando o plano.
5. Repetir de forma balanceada e coletar sobre um log imutável. Publicar
   sucesso funcional, cadeia cumprida, rejeição esperada e timeout
   separadamente. Preservar a campanha anterior como exploratória.

## Reprodução da auditoria offline

```sh
mise exec -- mix run scripts/probe_methodology.exs
```

O script usa o resolver e o Agent reais com chat simulado de resposta
constante. Exercita propagação de instruções, nudges e exemplos sintéticos
dos critérios de arquivo/contagem. Não se trata de novas falhas observadas
nos providers nem de uma nova matriz de desempenho.
