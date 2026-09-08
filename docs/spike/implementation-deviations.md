# Correção dos desvios de implementação

Esta correção parte das decisões do usuário e dos contratos de Agent,
política, avaliação parental e etapa review. A documentação atualizada junto
com uma implementação não serve, sozinha, como prova de conformidade.
Os resultados reais anteriores permanecem históricos.

## Rastreabilidade

| Decisão de referência | Desvio encontrado | Correção e verificação |
| --- | --- | --- |
| Agent configura capacidades; política determina autoridade efetiva (`execution-model.md`, `tool-policy.md`) | O loader ignorava tools do agente e a política substituía sua lista | `agents.<nome>.tools` restringe a política existente; nomes/grupos são validados. Teste integrado confere as tools pinadas e os efeitos permitidos/negados na etapa |
| Pai avalia e pode delegar verificações (`execution-model.md`) | Duas listas fixas de leitura removiam delegate durante assessment | Removidas as duas restrições. Teste delega durante a avaliação e conclui primeiro a verificação, depois o alvo original e a raiz |
| Papel reviewer executa a etapa review; contexto depende da etapa | Perfil de execução aparecia como ordem adicional no review | Perfil e tarefa original são critérios de referência; instruções da etapa definem a ação atual. A nova etapa recebe também o checkpoint confirmado das ferramentas |
| Seletores referem agentes/times configurados (`team-model.md`) | Nomes inventados viravam workers por depth | Core valida a delegação mesmo sem lane explícita. Teste rejeita agente e time inexistentes antes de criar filhos. O resolver não substitui nome explícito inexistente por worker |
| Relato e comentário preservam efeitos para decisão do pai | Correção de JSON podia chamar ferramentas novamente | Correção estrutural entra em modo somente relato, rejeitando novas chamadas antes dos efeitos. Teste tenta repetir counter e verifica que permaneceu em 1 |

O reviewer padrão tem uma lista configurável de ferramentas de leitura e
delegação, sujeita ao teto da política. Não há uma regra semântica no harness
que julgue a qualidade da revisão. Uma configuração explícita pode escolher
outras capacidades para esse agente.

## Continuidade da avaliação

Permitir delegação pelo pai exigiu corrigir uma premissa anterior do
checkpoint: uma avaliação que aguarda verificação ainda não terminou.
Seu contexto e alvo são persistidos no checkpoint da espera. Após a
verificação ser aprovada, a avaliação original é retomada. O checkpoint
anterior do pai é restaurado ao concluir a avaliação, preservando os efeitos
que suas ferramentas autorizadas produziram. Um teste percorre três Runs
do pai e confere a continuidade do contador em `[1,2,3]`.

A mediação entre linhagens também conserva a descoberta configurada em seu
snapshot; assim a validação dos seletores não depende de inventar um fallback
quando a mediação encaminha uma delegação válida.

## Validação e limites

Testes específicos estão em `agent_contract_test.exs`, `workflow_test.exs`
e `agent_test.exs`. O teste integrado de ferramentas por etapa verifica
política pinada, chamada negada, leitura permitida, contexto e replay.
Fixtures de descoberta e fake agora declaram os times que utilizam.

A suíte completa passou com **312 testes, 0 falhas**, seed `784729`,
em 10,7 segundos (`mise exec -- mix test`). Formatação dos arquivos alterados
e links da documentação foram conferidos. Nenhum novo benchmark com providers reais foi executado nesta correção. Portanto,
não se afirma confiabilidade de ponta a ponta nem conclusão integral de
todo o TO-BE com base nesses testes.
