# Adicionar ou alterar uma UI

Os layouts ficam em `lib/omunculus/cli/ui/`. Cada arquivo cuida somente de
formatação e retorna `{estado, linhas}`. Não lê banco, não executa ferramentas
e não interpreta decisões do modelo. `CLI.Reporter` escreve as linhas;
`CLI.UI` prepara os mesmos eventos para todos os layouts.

Para mudar separadores, recuos ou títulos, edite o layout. Para mudar o conteúdo
comum, edite `CLI.UI`. Para adicionar uma opção:

1. Crie um módulo com `@behaviour Omunculus.CLI.UI`.
2. Implemente as três funções abaixo.
3. Registre o nome em `CLI.UI.layouts/0` e atualize a lista no help de
   `cli/spec.ex` e `omunculus.usage.kdl` e a mensagem de validação.

```elixir
defmodule Omunculus.CLI.UI.Compact do
  @behaviour Omunculus.CLI.UI
  def init(ctx), do: {nil, ["#{ctx.mode} · #{ctx.path}"]}
  def event(item, state) do
    {state, [item.title] ++ item.lines}
  end
  def finish(state), do: {state, []}
end
```

`item` contém `kind` (`:start`, `:event`, `:end`), `title`, `lines`, `run_id`,
`work_item_id`, `depth`, `sequence` e `timestamp`. As linhas de conteúdo já
respeitam `--detail` e escapam caracteres de controle. O estado do layout pode
ser `nil`, como em timeline/tree, ou um mapa, como em blocks. Não é necessário
alterar Reporter, leitor de replay ou Runtime para adicionar uma UI.

Os layouts são progressivos e cronológicos. `tree` indenta pelo depth registrado
e mostra os vínculos explícitos, sem reordenar Runs concorrentes. `blocks`
marca a retomada da exibição; isso não significa retomar a execução de uma Run.
`run.completed` fecha visualmente uma Run, nunca aprova implicitamente uma tarefa.

Teste com `mise exec -- mix test test/omunculus/cli/ui_test.exs`. Os testes percorrem
os layouts registrados e comparam live/replay usando os mesmos eventos.
Para revisar o resultado manualmente, reconstrua com `mise exec -- mix escript.build`
e compare uma sessão gravada usando `session replay ID --db ARQUIVO --ui NOME`.
