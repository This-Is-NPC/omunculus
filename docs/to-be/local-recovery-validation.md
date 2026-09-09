# Recuperação com modelo local

## Critérios antes da implementação

Os cenários de recuperação usam um único contador por sessão, compartilhado entre
Work Items e Runs. Abrir nova delegação não zera efeitos. O recurso de teste é um
processo com atualização atômica, mantido vivo durante reinícios do runtime; o
checkpoint é evidência, não a autoridade do recurso compartilhado. Não simula
persistência após queda do serviço externo inteiro.

A fixture começa com valor 4 e objetivo 3 para garantir que toda execução encontre
o problema de recuperação, sem depender de o modelo cometer um erro aleatório.
No caso recuperável, increment/decrement são expostos: sucesso exige valor final
3, exatamente um decremento, aprovação do pai e conclusão da raiz. No caso
irreversível só incremento está disponível: sucesso do protocolo exige nenhuma
mutação adicional e escalada humana explícita, sem alegar conclusão da tarefa.
Tempo é apenas métrica. O avaliador não interfere nas decisões do runtime.

O pai deve devolver completed=false com correção no comment para retomar o mesmo
Work Item. Nova delegação significa outro trabalho sobre o mesmo recurso. Os
retries continuam limitados pelo orçamento persistido. Resumo distingue retornos
observados de alegações e preserva identificadores literalmente ou os omite.

## Ordem

1. Ferramenta compartilhada e operações configuradas pelo cenário.
2. Ajustes nos papéis worker, concierge e summarizer em Markdown.
3. Testes de isolamento entre sessões, concorrência, retomada do filho, comment,
   efeitos preservados, orçamento após reinício e escalada.
4. Matriz real depth 1: recuperável/irreversível × interceptor ligado/desligado,
   usando presets/local.toml e o mesmo contrato de eventos.

O contador com estado no contexto continua disponível para testes unitários de
checkpoint; os cenários reais fornecem explicitamente um recurso compartilhado.
São recursos de teste distintos, não formatos de compatibilidade.

## Executar

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml plain --depth 1 --recovery repair --interceptor off
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml plain --depth 1 --recovery repair --interceptor on --interceptor-input without-report
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml plain --depth 1 --recovery escalate --interceptor off
mise exec -- mix run scripts/validate_workflow.exs presets/local.toml plain --depth 1 --recovery escalate --interceptor on --interceptor-input without-report
```

`--recovery none` mantém o objetivo de três incrementos a partir de zero, agora
sobre um recurso compartilhado neste runner. `repair` e `escalate` usam workflow
plain; o caso staged permanece dedicado à validação das transições de etapas.
Os resultados exportam `counter_initial`, `counter_final`, `expected_outcome` e
`scenario_success`. `task_success` continua falso quando a tarefa não foi concluída,
mesmo se escalar corretamente satisfizer o cenário irreversível. A análise também
inspeciona a justificativa do break; somente chegar a um pedido humano não prova
que o modelo reconheceu a impossibilidade.

As ferramentas aceitam apenas `{}`. `counter_decrement` atua sobre o mesmo recurso
que `counter` e só é concedido pelo perfil do caso recuperável. O runtime registra
`previous`/`new` para ambas; não compara o valor com o objetivo. A suíte controlada
verifica recusa de argumentos fora do schema antes de qualquer efeito.

## Falha de transporte identificada na validação

A primeira tentativa com interceptor esgotou o timeout HTTP de 120 segundos em
duas chamadas do resumidor final. Os efeitos já estavam corretos, mas a interação
escalou após seu retry. Isso é registrado separadamente da avaliação funcional.
O prazo passou a ser configurável em `[chat].timeout_ms`; o preset local usa
`"infinity"`. A sessão com timeout foi preservada e o cenário repetido em uma nova
sessão. Não foi mudado o objetivo para declarar sucesso da sessão interrompida.
