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

Use `./omunculus --help` para a referência completa.

## Comandos atuais

- `run <dir> <instrução...>` executa o Agent;
- `monkey-job <instrução...>` executa um diagnóstico com tools selecionáveis;
- `benchmark` mede cenários de densidade, árvore residente sintética ou carga
  HTTP de diagnóstico;
- `spike` executa a spike do Event Core planejado (SQLite, `EVENTS`,
  delegação em runtime, replay) com uma tarefa de contagem sem provider;
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
- [Arquitetura TO-BE (planejada)](docs/to-be/architecture.md)
- [Modelo de dados TO-BE (planejado)](docs/to-be/data-model.md)
- [Requisitos TO-BE (planejados)](docs/to-be/requirements.md)
- [Event Core e eventos TO-BE (planejado)](docs/to-be/event-model.md)
- [Execução e delegação TO-BE (planejado)](docs/to-be/execution-model.md)
- [Comparação de harnesses TO-BE vs. Pi, Claude Code e Codex](docs/to-be/harness-comparison.md)
- [Spike do Event Core (branch `spike/event-core`)](docs/spike/event-core-spike.md)

## Testes

```sh
mix test
```
