# Benchmark linear de agentes residentes

Uma execução por perfil de hardware. O driver acrescenta **um agente por vez**,
mantém todos os anteriores vivos e continua até OOM, erro do agente, travamento
na inicialização ou encerramento do processo. Não há duplicação da concorrência,
busca binária, reinício por ponto nem reprovação por p95.

| Perfil | Quota agregada de CPU | RAM | Swap |
|---|---:|---:|---:|
| A | 100% (equivalente a 1 CPU) | 512 MiB | 0 |
| B | 200% (equivalente a 2 CPUs) | 1 GiB | 0 |

CPU fixa é opcional (`--pin-cpus`). Por padrão, o escalonador do host escolhe
as CPUs disponíveis e o cgroup limita o tempo agregado de processamento.

## Executar

No terminal do host, dentro do repositório:

```sh
mise run benchmark:build
mise run benchmark:check
mise run benchmark:run
```

O último comando roda A até falhar, limpa seus processos e roda B até falhar.
Usa systemd de usuário e delegação de `cpu`, `memory` e `pids`; só exige `cpuset`
se `--pin-cpus` for solicitado. Não altera a configuração do host.

```sh
# Mudar apenas a cadência linear (um agente a cada intervalo mínimo):
mise run benchmark:run --interval-ms 50

# Contexto de 1 MiB por agente, em vez dos 64 KiB padrão:
mise run benchmark:run --context-bytes 1048576

# Teste funcional limitado; não é uma medição do teto:
mise run benchmark:run --max-agents 3

# Regerar o relatório:
mise run benchmark:report
```

O passo é sempre 1. O intervalo padrão é 100 ms; a criação seguinte também
aguarda a anterior montar a run. Assim, uma fila de pedidos ainda não iniciados
não vira uma contagem falsa de agentes residentes. `--max-agents` só existe para
verificação curta; sem ele, a execução continua até falhar.

## O que é medido

O driver é Elixir e chama `Project.open`, `Run.open`, montagem de contexto,
permissões, persistência e o cliente OpenAI reais. Cada agente tem contexto
próprio materializado, conexão SQLite própria e compartilha banco/workspace com
os demais. A admissão é serializada até a run estar montada; os agentes já
admitidos continuam simultaneamente vivos aguardando o modelo.

O modelo simulado é **o stub Rust da master**, copiado sem alterações de
`priv/benchmark_stub` em `3a484b6`; consulte [origem](stub/PROVENANCE.md).
Sua resposta é adiada por 24 horas, permitindo manter as chamadas em voo durante
a rampa. O timeout do cliente é maior que essa espera. O coletor confirma a
residência cruzando runs montadas com o pico real de HTTP simultâneo no stub.

O pool HTTP do driver de benchmark é explicitamente configurado para 65.536
conexões, abertas sob demanda, evitando que o padrão de 50 conexões substitua o
limite de hardware. Isso não altera o cliente de produção. Limites de FD/PIDs
herdados do host continuam registrados e podem ser a causa de falha.

O lançador/coletor também é **Rust**. Não há Python neste benchmark. Stub e
coletor ficam fora do orçamento; BEAM e seus descendentes entram no cgroup antes
do exec. CPU, memória, swap e limites ancestrais são verificados. O coletor
sobrevive ao OOM para guardar evidências e encerrar somente o grupo criado.
A release e os binários Rust são compilados antes da medição.

Este é o teto observado de **agentes residentes aguardando modelo**, não uma
medição de throughput nem de centenas de comandos executando simultaneamente.
Não se deve generalizar esse número para agentes rodando Python, Deno ou CLIs
pesados. O banco, page cache e toda memória da BEAM entram no orçamento.

## Resultados

`bench/results/` contém somente a última execução e fica gitignored.
Uma nova execução substitui esse resultado. Para guardar uma medição separada,
use `--output DIRETORIO_NOVO` explicitamente.
Binários e caches de compilação ficam em `_build/bench/native/`.

Arquivos da medição:

- `manifest.json`: versões, hardware, limites herdados e parâmetros.
- `A/config.json` e `B/config.json`: configuração de cada driver.
- `A/agents.ndjson` e `B/agents.ndjson`: sequência linear de criação/montagem.
- `A/samples.ndjson` e `B/samples.ndjson`: cgroup e stub a cada 250 ms.
- `A/result.json` e `B/result.json`: último número confirmado e motivo da parada.
- `summary.csv` e `report.md`: comparação dos dois orçamentos.

Os workspaces sintéticos são descartados após cada perfil. Os logs e as amostras
permanecem. `oom` é falha do orçamento; `agent_error` identifica falha do harness;
`exploration_limit` é um limite explícito de teste, não o teto da máquina.
O último número confirmado é conservador devido ao intervalo de coleta.

O timeout de montagem de um agente é 30 segundos. Isso permite registrar um
travamento em vez de esperar indefinidamente sem acrescentar agentes. Uma
interrupção pelo usuário é registrada como interrupção, nunca como capacidade.
