Status: AS-IS — implementado

# Requisitos atuais

Requisitos abaixo são observáveis na CLI, na especificação KDL e nos testes;
não são requisitos do alvo planejado. Consulte [architecture.md](architecture.md)
e [data-model.md](data-model.md) para os limites desta versão.

## Interface CLI

O binário `omunculus` oferece:

- `run <dir> <instruction...>`: executa o Agent no diretório;
- `monkey-job <instruction...>`: executa o mesmo loop com controle explícito
  de tools, atraso de observação e `counter`;
- `benchmark`: executa cenários de diagnóstico `actor-density`, `agent-tree` e
  `http-load`;
- `help` e `version`.

`-h/--help`, `-V/--version` e `--verbose` são flags globais. Argumentos
obrigatórios e flags desconhecidas produzem erro de uso. Os códigos definidos
são 0 para parada sem erro de host/chat, 1 para erro de host/chat/runtime e 2
para erro de uso.

## Execução

1. Canonicalizar o diretório de trabalho e impedir escape por symlink ou
   caminho fora da raiz.
2. Resolver configuração na precedência flags > ambiente > TOML > defaults.
3. Enviar a instrução ao chat com schemas somente das tools permitidas.
4. Repetir chamadas e observações até resposta final ou `max_turns`.
5. Escrever a resposta final em `stdout`; timeline e tabela do reporter vão para
   `stderr` quando aplicável.

O modelo pode ler e alterar somente através das tools permitidas. O processo
não executa shell nem faz commit Git. O chat implementado é OpenAI-compatible,
sem streaming; `fake` permite testes determinísticos.

## Configuração e diagnóstico

A configuração aceita TOML, presets `coding` e `plan`, variáveis `${NAME}`,
modelo, URL base, autenticação, limite de turnos e formato de timestamp UTC.
`monkey-job` começa sem catalogo de tools salvo opção `--tools`; `--delay`
retarda a entrega das observações e `--increment` configura o `counter`.

O benchmark mede runtime residente, ou carga do stub HTTP interno; seus limites
de RSS/CPU são controles soft de diagnóstico. `agent-tree` é sintético e
provider-free; não observa runs duráveis.

## Evidência e limites

Os testes cobrem parser/help/reporter, configuração TOML/env/dotenv, Agent e
chat fake/completions, sandbox e tools, autenticação e benchmarks. Não há
requisito implementado para persistência, requests humanas, workflow,
hierarquia de delegação, recuperação, replay ou tabela central de eventos.
Esses itens pertencem explicitamente ao [alvo TO-BE](../to-be/requirements.md)
e não devem ser inferidos como disponíveis hoje.
