# Omunculus

Restart greenfield. Os documentos de planejamento em `.temp/` são locais
e não fazem parte do repositório.

Elixir 1.17, OTP 27 e Deno 2.9 (sandbox JavaScript), definidos em `mise.toml`.

Execute `mix test`. O teste com modelo real requer `--include local_model`,
`OMUNCULUS_OPENAI_URL` e `OMUNCULUS_OPENAI_MODEL`.

O adaptador oferece chamadas nativas e `__omunculus_execute` para código
JavaScript com `await tools.nome(args)`. O sandbox não tem acesso direto
a arquivos, rede, ambiente ou subprocessos; as tools passam pelo harness.

O harness antigo ficou em `master`.
