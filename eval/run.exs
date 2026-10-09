# Equivalent Exchange: `mix run eval/run.exs <command>`.
#   selftest   prove every task's check against its solution
#   run        run the suite: --model luna --k 2 --label <name> [--task <part>]...
#              [--configuration <name>]... [--timeout <seconds>] [--jobs <n>]
#   score      score again every execution of a result folder, then its report
#   report     write a result folder's summary, report and comparison
#   compare    compare two result folders, the earlier first
for file <- ~w(project task score report selftest runner),
    do: Code.require_file("lib/#{file}.ex", __DIR__)

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
          timeout: :integer,
          jobs: :integer
        ]
      )

    {:ok, folder} = EquivalentExchange.Runner.run(options)
    IO.puts(folder)

  ["score", folder] ->
    for path <- Path.wildcard(Path.join([folder, "executions", "*", "*", "*", "execution.json"])) do
      execution = path |> File.read!() |> Jason.decode!()
      scored = Map.put(execution, "score", EquivalentExchange.Score.score(execution))
      File.write!(path, Jason.encode!(scored, pretty: true))
    end

    EquivalentExchange.Report.write(folder)
    IO.puts(folder)

  ["report", folder] ->
    EquivalentExchange.Report.write(folder)
    IO.puts(Path.join(folder, "report.md"))

  ["compare", before, now] ->
    IO.puts(EquivalentExchange.Report.compare_folders(before, now))

  _other ->
    IO.puts(
      "usage: mix run eval/run.exs selftest | run [options] | score <folder> | report <folder> | compare <before> <now>"
    )

    System.halt(1)
end
