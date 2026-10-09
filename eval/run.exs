# Equivalent Exchange: `mix run eval/run.exs <command>`.
#   selftest   prove every task's check against its solution
for file <- ~w(project task selftest), do: Code.require_file("lib/#{file}.ex", __DIR__)

case System.argv() do
  ["selftest"] ->
    case EquivalentExchange.Selftest.run() do
      :ok ->
        IO.puts("every check holds")

      {:error, problems} ->
        Enum.each(problems, &IO.puts/1)
        System.halt(1)
    end

  _other ->
    IO.puts("usage: mix run eval/run.exs selftest")
    System.halt(1)
end
