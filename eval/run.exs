# Equivalent Exchange: `mix run eval/run.exs <command>`.
#   selftest   prove every task's check against its solution
#   run        run the suite: --model luna --k 2 --label <name> [--task <part>]...
#              [--configuration <name>]... [--timeout <seconds>] [--jobs <n>]
#   score      judge and score again every execution of a result folder, then its report
#   report     write a result folder's summary, report and comparison
#   compare    compare two result folders, the earlier first
for file <- ~w(project task judge score report selftest runner),
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
    tasks = Map.new(EquivalentExchange.Task.all(), &{&1.id, &1})

    for path <- Path.wildcard(Path.join([folder, "executions", "*", "*", "*", "execution.json"])) do
      id = path |> File.read!() |> Jason.decode!() |> Map.fetch!("task")

      # An execution of a task since removed keeps the score it had.
      with {:ok, task} <- Map.fetch(tasks, id) do
        assessed = EquivalentExchange.Runner.reassess(path, task)
        File.write!(path, Jason.encode!(assessed, pretty: true))
      end
    end

    manifest = Path.join(folder, "manifest.json")

    manifest
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("judge", EquivalentExchange.Runner.judge_trust())
    |> Jason.encode!(pretty: true)
    |> then(&File.write!(manifest, &1))

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
