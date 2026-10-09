# Equivalent Exchange: `mix run eval/run.exs <command>`.
#   selftest   prove every task's check against its solution
#   run        run the suite: --model luna --k 2 --label <name> [--task <part>]...
#              [--configuration <name>]... [--timeout <seconds>]
for file <- ~w(project task selftest runner), do: Code.require_file("lib/#{file}.ex", __DIR__)

case System.argv() do
  ["selftest"] ->
    case EquivalentExchange.Selftest.run() do
      :ok ->
        IO.puts("every check holds")

      {:error, problems} ->
        Enum.each(problems, &IO.puts/1)
        System.halt(1)
    end

  ["run" | argv] ->
    {options, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          model: :string,
          k: :integer,
          label: :string,
          task: :keep,
          configuration: :keep,
          timeout: :integer
        ]
      )

    {:ok, folder} = EquivalentExchange.Runner.run(options)
    IO.puts(folder)

  _other ->
    IO.puts("usage: mix run eval/run.exs selftest | run [options]")
    System.halt(1)
end
