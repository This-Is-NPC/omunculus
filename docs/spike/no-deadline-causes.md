# Causas observadas na campanha sem prazo

Análise dos bancos registrados em [no-deadline-validation.md](no-deadline-validation.md)
e do código em `94df95d`. Não foram alterados prompts, runtime ou configuração
nesta análise. [Resultados completos](no-deadline-results.json).

## Desfechos

| Cenário | Desfecho do protocolo | Efeitos | Runs | Chamadas de modelo concluídas |
| --- | --- | --- | --- | --- |
| Cloud sem fluxo | Raiz concluída | 15 incrementos, em cinco filhos | 16 | 41 |
| Cloud com review | Intervenção humana | 4 incrementos | 5 | 14 |
| Qwen sem fluxo | Intervenção humana | 58 incrementos, em diferentes filhos | 50 | 139 |
| Qwen com fluxo | Intervenção humana antes de review | 6 incrementos | 8 | 16 |

Intervenção humana deixa a decisão pendente. A incorreção dos efeitos é uma
observação externa independente. Duração não determina reprovação.

## 1. O contexto mistura execução e verificação

No cloud com fluxo, o checkpoint do evento 38 contém simultaneamente:

- Etapa review: “Do not increment counter again.”
- Perfil count: “Call it once per increment until it returns the target.”
- Mensagem de tarefa: a instrução original para executar os incrementos.

A seleção do reviewer ocorreu corretamente, mas `Prompt.compose` inclui o
perfil de execução nessa etapa e `Workflow` reapresenta a tarefa original.
O modelo chamou `counter` como verificação, chegando a 4. Isso é uma decisão
errada diante da proibição explícita, em um contexto que também manda executar.
A contribuição específica de cada instrução ainda exige ablação controlada.

## 2. A capacidade disponível permite danificar o resultado

O reviewer herdou `counter` pela política do perfil. Alterar agente/kind/prompt
não restringiu as ferramentas. Não havia uma leitura sem mutação desse
contador. A etapa recebeu o comentário do pai, enquanto o estado real ficou
no checkpoint da ferramenta. O resultado foi uma verificação com efeito.

A descrição em `tools/counter.ex` diz que o contador começa no zero e persiste
na mesma Run. Na execução real, o checkpoint o transporta entre Runs do mesmo
Work Item. Essa descrição incompleta pode induzir uma expectativa incorreta
sobre estado, embora sua influência isolada não tenha sido medida.

Depois de incrementar indevidamente, o reviewer cloud reconheceu o erro e
emitiu break. O pai também escalou. O mecanismo funcionou; a intervenção
humana foi um desfecho coerente para um contador monotônico sem reset.

## 3. Reparação do relato volta ao ciclo de ferramentas

No Qwen com fluxo, o evento 25 preserva esta sequência na primeira Run:
`1 → 2 → 3 → 4 → resposta textual → pedido de JSON → 5 → break`.
O quarto incremento foi erro do modelo antes da correção de formato.
O quinto ocorreu depois da correção: `Agent.loop` volta a disponibilizar
as ferramentas ao pedir um relato estruturalmente válido.

No cloud com fluxo, o executor precisou de três correções de formato após
atingir 3. O reviewer também mudou sua decisão durante as correções: primeiro
aprovava o resultado apesar do incremento extra; ao final reconheceu o defeito
e escalou. Portanto, reparação não é um simples custo de serialização: pode
alterar ações e julgamentos dentro da Run.

O prompt pede terminar com JSON, mas o parser aceita somente a resposta
inteira em JSON. Texto com JSON em Markdown foi rejeitado. Há espaço para
corrigir a instrução estrutural sem julgar automaticamente qualidade.

## 4. Aprovar um filho não encerra a coordenação do pai

No cloud sem fluxo, a raiz aprovou cinco filhos sucessivos. A primeira nova
delegação pediu explicitamente reexecução (evento 32); outras pediram confirmar
as evidências (59, 82, 109), mas os workers repetiram os incrementos. O perfil
continuava instruindo execução. A raiz acabou declarando sucesso com 15 efeitos.

No local sem fluxo, foram dez continuações do pai e onze filhos criados.
O limite de retries é por Work Item/etapa; novas delegações abrem outros
Work Items e não consomem o orçamento de retry do filho anterior. Portanto,
`max_retries=2` não limita esse ciclo de coordenação a duas tentativas totais.
Isso explica a multiplicação de trabalho, sem significar que o harness deva
decidir semanticamente quando uma delegação é desnecessária.

## 5. Seletores inventados são aceitos como papéis diferentes

O Qwen delegou para `worker-1`, `supervisor-1` e outros nomes não configurados,
com equipes também inventadas. No evento 32 do local sem fluxo, o agente
`supervisor-1` iniciou com `agent_kind=worker` e recebeu o perfil count.

`Scripts.pick_agent` aceita um nome explícito, e `Agents.default_agent` usa
um papel por depth quando não encontra a configuração. O modelo pediu uma
supervisão fictícia; o harness a materializou como executor. A validação
estrutural do seletor deveria tornar essa diferença visível, sem inferir a
qualidade do trabalho. Neste caso sem máquina não houve desvio de fluxo;
o risco de perder um fluxo ligado ao nome do agente merece teste próprio.

## 6. Falhas técnicas e intervenções prolongaram a execução local

O local sem fluxo registrou dois `run.failed` por `Req.TransportError`
com motivo `:timeout`, nos eventos 39 e 122. São falhas reais de requisição,
diferentes do corte artificial removido do teste. O pai recebeu os breaks.
Houve 139 chamadas de modelo concluídas, 50 Runs, retries e novas delegações.
A duração longa não foi evidência de um processo pai parado aguardando filho;
os eventos mostram múltiplas execuções e decisões, além das falhas de transporte.

## Conclusão e controles recomendados

Há erros de modelo e fragilidades do harness/contexto que os amplificam.
Esta campanha não demonstra que modelos menores são inviáveis, nem atribui
tudo ao harness. Avanço, replay e escalonamento foram observados; seleção
permissiva de agentes, instruções conflitantes e efeitos durante reparação
são fronteiras concretas para correção e novos testes.

Prioridade: tornar explícitas as instruções e capacidades de cada papel/etapa,
rejeitar seletores inexistentes e impedir que uma correção exclusivamente de
formato volte a executar trabalho. Validar cada mudança isoladamente contra
os mesmos cenários, com o mesmo modelo e sem corte de tarefa por duração.
A decisão semântica de concluir, corrigir ou escalar continua com o pai.
