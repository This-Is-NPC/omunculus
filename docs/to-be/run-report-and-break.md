# Trabalho, execução, aprovação e break

Contrato de referência; desvios corrigidos e verificações específicas em
[aderência da implementação](../spike/implementation-deviations.md). Validação histórica e limites em
[workflow-validation.md](../spike/workflow-validation.md). A aprovação pertence ao agente responsável; o
harness registra e aplica a decisão. Os testes devem verificar este contrato,
não apenas se uma Run devolveu texto.

## Duas dimensões do Work Item

`status` representa o andamento do trabalho: sem máquina, `to_do`,
`in_progress`, `completed`; com máquina, o nome da etapa configurada até
`completed`. `state` representa execução: `active` (pronto), `running`,
`waiting`, `failed`, `idle` (sem execução ou espera pendente).

Criar uma tarefa ou delegar cria um Work Item. Delegação liga o filho por
`parent_work_item_id`. Retry, revisão e continuação criam Runs, não novas
cópias do trabalho. Iniciar ou encerrar uma Run não aprova a tarefa.
Falha preserva o `status`, registra `state = failed` e chega ao responsável.

## Relato e aprovação

Toda Run executora termina com o relato do modelo:

```json
{"completed":false,"comment":"Arquivo criado; falta verificar as referências."}
```

`comment` é resumo e orientação para a próxima Run. Não existe campo
separado de instrução de correção. `break: true` pede intervenção imediata e
exige `completed: false`. Handoffs por ferramentas exigem `comment`.
Delegar produz `work_item` e `comment`, conforme o
[contrato entre Runs](work-item-handoff.md); a definição da tarefa fica no Work Item.
O relato é JSON puro. Após um erro estrutural no relato, as respostas
seguintes nessa Run servem somente para corrigir o formato: novas chamadas
de ferramentas são rejeitadas antes de executar efeitos. O orçamento de
turnos continua valendo; correções estruturais também consomem `max_retries`.
Esgotar um desses limites devolve um relato incompleto com break.
Isso não introduz julgamento automático da qualidade da tarefa.
Arbitragem de permissão e trabalho entre linhagens mantém suas ferramentas
próprias de decisão; não aprova etapas implicitamente.

O relato do filho gera `task.assessment_requested`, nunca uma conclusão
antecipada. Uma Run de avaliação da entrega pelo pai recebe o alvo, etapa, tarefa,
comentários e evidências confirmadas. Usa o mesmo relato para aprovar,
pedir correção ou escalar. Seu checkpoint próprio e dependências são
restaurados ao encerrar a avaliação. A aprovação do filho não conclui o pai.
O pai conserva suas capacidades configuradas e pode delegar uma verificação.
Nesse caso, a avaliação suspensa guarda seu alvo e checkpoint; a aprovação
do verificador permite retomá-la, sem aprovar implicitamente o alvo original.

Sem máquina, aprovação emite `task.completed`. Com máquina, aprovação emite
`task.advanced` e agenda nova Run do mesmo Work Item; a aprovação da última
etapa emite `task.completed`. O harness escolhe o próximo estado pela
sequência configurada, sem julgar qualidade e sem depender do modelo
lembrar de iniciar a verificação.

A raiz se autoavalia por padrão. `root_approval = "human"` encaminha sua
conclusão à inbox. Concierge é uma configuração de agente, sem privilégio
especial nesse protocolo.

## Avaliação pelo pai e gate de review

Avaliar a entrega do filho é coordenação do agente pai (`reason = assessment`);
isso preserva seu papel e não ativa um gate. O papel reviewer pertence à
Run que executa a etapa `review` configurada no Work Item. A etapa seleciona
sua configuração de agente por `agent`; modelo, kind e prompt vêm dessa
configuração. O harness inicia essa Run ao entrar na etapa, em contexto novo.
O resultado do reviewer também é entregue ao pai para a decisão de avanço.

Sem máquina, não há etapa review nem ativação automática de reviewer.

## Configuração opcional

```toml
[defaults]
workflow = false
root_approval = "self"
max_retries = 2

[workflows.delivery]
steps = [
  { name = "to_do", instructions = "Planeje o trabalho e registre critérios." },
  { name = "in_progress", instructions = "Implemente o trabalho planejado." },
  { name = "review", agent = "reviewer", instructions = "Verifique o solicitado contra os efeitos e evidências." }
]

[agents.worker]
workflow = "delivery"
```

Agente, perfil e defaults resolvem a seleção nessa ordem. `false` desativa
explicitamente a máquina. Etapas têm nomes únicos e instruções não vazias;
`completed` é reservado à conclusão. O fluxo resolvido fica fixado no
primeiro `run.started` do Work Item. Revisões usam a etapa do alvo; a
configuração do pai não substitui o fluxo do filho.

Cada etapa começa em contexto novo com tarefa, instruções da etapa,
comentário do responsável e evidências persistidas. Retry conserva o
checkpoint daquela etapa. Ferramentas e políticas continuam limitando
capacidade, independentemente das instruções.

## Correção, falhas e recuperação

Reprovação mantém a etapa e agenda retry com o comentário do pai, até
`max_retries` por etapa. Sem máquina, trabalho reprovado fica `in_progress`.
O orçamento não zera ao reiniciar; avançar inicia o orçamento da nova etapa.
`task.recovery_used` reserva cada recuperação atomicamente e sem duplicá-la no
replay. Também consomem o limite as correções de ferramentas/relatos inválidos,
as delegações de verificação e novas delegações em continuação de trabalho
aprovado. Verificadores e descendentes compartilham o orçamento do alvo.
A primeira execução, delegação inicial com vários filhos e avaliação dos
resultados não consomem recuperação.

Falha técnica não repete efeitos automaticamente: `task.break` entrega o
problema ao responsável. Ele pode reconhecer efeitos já realizados,
autorizar outra tentativa ou escalar. Intervenções também têm limite; o
break sobe até o humano. Sem responsável acima, a inbox recebe o pedido.

Uma resposta textual na inbox solicita retry, sujeito ao orçamento restante; `--completed` aprova o alvo
com comentário obrigatório. Aprovação humana também respeita o avanço por
etapas. Pedidos não expiram por timeout.

Pedidos de revisão, resolução, transição e agendamento são eventos duráveis.
Reinício reconstrói pendências; eventos repetidos não duplicam avanço ou
execução. Nenhuma Run permanece viva aguardando outra Run.

Existe um único protocolo atual, usado por providers reais e simulados.
Não há migração, decoder ou execução de contratos antigos. Bancos de
validação são novos; replay aplica somente o contrato atual.
