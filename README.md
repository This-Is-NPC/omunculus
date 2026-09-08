# Omunculus

Omunculus é um harness de coding agent em Elixir/BEAM. A CLI recebe um
diretório e uma instrução, conversa com um endpoint compatível com OpenAI e
usa tools de filesystem dentro da raiz informada. Não executa shell, não cria
commits e não permite escape da raiz.

## Uso rápido

Requisitos: Elixir 1.17 e OTP 27.

```sh
mix deps.get
mix escript.build
./omunculus run ./meu-projeto "Crie um README para este projeto"
```

Uma sessão de teste determinística pode ser executada assim:

```sh
./omunculus send "conte até 10" --provider fake --profile count \
  --config test/fixtures/config/simple.toml --session /tmp/omunculus-demo.db
./omunculus events follow --db /tmp/omunculus-demo.db
```

Para o provider real, use `--provider chat` e configure endpoint/modelo no
TOML ou em flags. O antigo comando `spike` foi removido. O executor durável
usa `setsid` e `flock` no Linux; o SQLite continua sendo a fonte de verdade.

Use `./omunculus --help` para a referência completa.

## Comandos atuais

- `run <dir> <instrução...>` executa o Agent;
- `monkey-job <instrução...>` executa um diagnóstico com tools selecionáveis;
- `benchmark` mede cenários de densidade, árvore residente sintética ou carga
  HTTP de diagnóstico;
- `send <instrução...>` executa na sessão durável; `--detach` devolve o controle
  enquanto o executor residente continua trabalhando;
- `session`, `workspace` e `inbox` gerenciam sessão, anexos e respostas;
- `events follow`, `emit` e `config check` inspecionam e operam o Event Core;
- `help` e `version` exibem ajuda e versão.

As tools padrão são `read`, `edit`, `write`, `grep`, `find` e `ls`. A tool
`counter` só é exposta quando solicitada. A resposta final vai para `stdout`;
progresso e resumo vão para `stderr`.

## Configuração

A configuração pode estar em `~/.omunculus/config.toml` e no
`omunculus.toml` do diretório, ou ser indicada por `--config`. O projeto inclui
presets `local.toml` e `cloud.toml` em `presets/`. Flags prevalecem sobre o
ambiente, que prevalece sobre TOML e defaults. Variáveis `${NAME}` devem ocupar
uma string TOML inteira; mantenha segredos fora do versionamento.

## Documentação canônica

- [Arquitetura AS-IS](docs/as-is/architecture.md)
- [Modelo de dados AS-IS](docs/as-is/data-model.md)
- [Requisitos AS-IS](docs/as-is/requirements.md)
- [Arquitetura TO-BE, com o mapa dos documentos](docs/to-be/architecture.md)
- [Arquivo de configuração TO-BE](docs/to-be/config.md)
- [Plano de implementação para o TO-BE](docs/to-be/implementation-plan.md)
- [Requisitos TO-BE](docs/to-be/requirements.md)
- [Modelo de dados TO-BE](docs/to-be/data-model.md)
- [Event Core e eventos TO-BE](docs/to-be/event-model.md)
- [Catálogo de eventos, interceptores e automações TO-BE](docs/to-be/event-catalog.md)
- [Execução e delegação TO-BE](docs/to-be/execution-model.md)
- [Sessão e workspaces TO-BE](docs/to-be/session-model.md)
- [Times, interação entre linhagens e descoberta TO-BE](docs/to-be/team-model.md)
- [Política de tools: teto, perfil, workspace e modos TO-BE](docs/to-be/tool-policy.md)
- [Permissões temporárias e negociação TO-BE](docs/to-be/permission-negotiation.md)
- [Recomendações de terreno (histórico)](docs/to-be/recommendations.md)
- [Comparação de harnesses TO-BE vs. Pi, Claude Code e Codex](docs/to-be/harness-comparison.md)
- [Spike do Event Core (branch `spike/event-core`)](docs/spike/event-core-spike.md)

## Testes

```sh
mix test
```

### Histórico de sessão

Preserve uma execução e reveja sua UI sem executar modelos ou ferramentas:

```sh
./omunculus run ./meu-projeto "Crie um README" --db ./execucao.sqlite3
./omunculus session replay <session_id> --db ./execucao.sqlite3
./omunculus session replay <session_id> --db ./execucao.sqlite3 > historico.txt
```

O replay imprime o prefixo completo disponível na abertura, incluindo prompts,
respostas, chamadas de ferramentas, rejeições, avaliações e transições registradas.
Termina mesmo que a tarefa esteja pendente. `run --db` imprime um novo `session_id`
e acrescenta a execução ao banco, mesmo que ele já exista. Sem essa flag, `run`
continua efêmero. O replay exige o ID; sem caminho de banco, usa o banco padrão.
Use `./omunculus session list --db ./execucao.sqlite3` para listar os IDs.

Os testes reais compartilham `test/sessions.sqlite3`:

```sh
mise exec -- mix run scripts/validate_workflow.exs presets/cloud.toml
./omunculus session list --db test/sessions.sqlite3
./omunculus session replay <session_id> --db test/sessions.sqlite3
```

O replay não retoma trabalho nem marca a inbox como lida.

Veja o [contrato de replay](docs/to-be/session-replay.md) e a
[validação](docs/spike/shared-session-validation.md).
