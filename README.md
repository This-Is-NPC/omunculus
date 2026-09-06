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
- [Arquitetura TO-BE, com o mapa dos documentos](docs/to-be/architecture.md)
- [Arquivo de configuração TO-BE (proposta)](docs/to-be/config.md)
- [Requisitos TO-BE](docs/to-be/requirements.md)
- [Modelo de dados TO-BE](docs/to-be/data-model.md)
- [Event Core e eventos TO-BE](docs/to-be/event-model.md)
- [Catálogo de eventos, interceptores e automações TO-BE](docs/to-be/event-catalog.md)
- [Execução e delegação TO-BE](docs/to-be/execution-model.md)
- [Sessão e workspaces TO-BE (proposta)](docs/to-be/session-model.md)
- [Times, interação entre linhagens e descoberta TO-BE (proposta)](docs/to-be/team-model.md)
- [Política de tools: teto, perfil, workspace e modos TO-BE (proposta)](docs/to-be/tool-policy.md)
- [Permissões temporárias e negociação TO-BE (proposta)](docs/to-be/permission-negotiation.md)
- [Recomendações de terreno (rationale)](docs/to-be/recommendations.md)
- [Comparação de harnesses TO-BE vs. Pi, Claude Code e Codex](docs/to-be/harness-comparison.md)
- [Spike do Event Core (branch `spike/event-core`)](docs/spike/event-core-spike.md)

## Testes

```sh
mix test
```
