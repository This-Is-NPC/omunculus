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
  alias Omunculus.CLI.UI.Text
  def init(ctx), do: {ctx.width, Text.lines("#{ctx.mode} · #{ctx.path}", ctx.width)}
  def event(item, width) do
    {width, Enum.flat_map([item.title | item.lines], &Text.lines(&1, width))}
  end
  def finish(state), do: {state, []}
end
```

`item` contém `kind` (`:start`, `:event`, `:end`), `title`, `lines`, `run_id`,
`work_item_id`, `depth`, `sequence` e `timestamp`. As linhas de conteúdo já
respeitam `--detail` e escapam caracteres de controle. O estado do layout pode
guardar a largura recebida em `ctx.width`, como em timeline/tree, ou um mapa,
como em blocks. Use `UI.Text.lines(texto, largura, prefixo, prefixo_de_continuação)`
para quebrar texto preservando o recuo e as linhas verticais. A largura vem do
terminal; saídas redirecionadas usam 100 colunas. Não é necessário
alterar Reporter, leitor de replay ou Runtime para adicionar uma UI.

Os layouts são progressivos e cronológicos. `tree` indenta pelo depth registrado
e mostra os vínculos explícitos, sem reordenar Runs concorrentes. `blocks`
usa apenas separadores horizontais e marca a retomada da exibição; isso não significa retomar a execução de uma Run.
`run.completed` fecha visualmente uma Run, nunca aprova implicitamente uma tarefa.

Teste com `mise exec -- mix test test/omunculus/cli/ui_test.exs`. Os testes percorrem
os layouts registrados e comparam live/replay usando os mesmos eventos.
Para revisar o resultado manualmente, reconstrua com `mise exec -- mix escript.build`
e compare uma sessão gravada usando `session replay ID --db ARQUIVO --ui NOME`.
