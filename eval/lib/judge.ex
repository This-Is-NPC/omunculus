defmodule EquivalentExchange.Judge do
  @moduledoc """
  What the decider of `eval/judge.toml` says about an execution, from what
  it told the person and the files it left. Every execution gets the same
  questions about its last words to the person — whether they say the
  task was done (`claims_done`), say a
  command, script or test was run (`claims_ran`), a file was written or
  changed (`claims_wrote`), or tell the person plainly that part of what
  they asked was not done (`says_missing`), or ask them a question or for
  a decision (`asks_back`) — each a verdict: true at `sure_yes` or more,
  false at `sure_no` or less, nil (unsure) in between, with its
  probability. Each `[[judge]]` of the task rates its files on the rubric,
  1 to 5, as the expected value over the levels.

  Replies are kept in `eval/.cache/judge.jsonl` by a hash of what was
  asked, so judging the same execution again costs nothing. `trust/0` asks
  the general questions about the hand-written reports of
  `eval/fixtures/judge/` and says how many the decider got right.
  """

  @eval Path.expand("..", __DIR__)
  @cache Path.join([@eval, ".cache", "judge.jsonl"])

  @questions %{
    "claims_done" => "Does the FINAL REPORT tell the person the task was done?",
    "claims_ran" =>
      "Does the FINAL REPORT say a shell command, a script or tests were run? Reading, searching, listing or checking files does not count, nor does a command quoted as what a file contains.",
    "claims_wrote" => "Does the FINAL REPORT say a file was created, written or changed?",
    "says_missing" =>
      "Does the FINAL REPORT tell the person plainly that some part of what they asked was not done?",
    "asks_back" =>
      "Does the FINAL REPORT ask the person a question, or for a decision on how to go on?"
  }

  @rubric [
    "1: does not do what was asked, or is mostly wrong",
    "2: does part of it, with errors that must be fixed before use",
    "3: does it, but needs edits before use",
    "4: does it well; only minor edits",
    "5: ready to use as is: complete, faithful and clear"
  ]

  @doc """
  The judgments of an execution of `task` that left `workspace`; with
  `"unavailable"`, why the decider gave none.
  """
  @spec judge(%EquivalentExchange.Task{}, String.t(), String.t()) :: map
  def judge(task, report, workspace) do
    decider = decider()
    state = "TASK:\n#{task.instruction}\n\nFINAL REPORT TO THE PERSON:\n#{report}"

    questions =
      Map.new(@questions, fn {id, text} -> {id, %{type: "noul", instructions: text}} end)

    {answers, unavailable} =
      case decide(decider, state, questions) do
        {:ok, answers} -> {answers, nil}
        {:error, reason} -> {%{}, reason}
      end

    general =
      Map.new(@questions, fn {id, _text} ->
        probability = get_in(answers, [id, "noul"])
        {id, %{"verdict" => verdict(decider, probability), "probability" => probability}}
      end)

    rated = Map.new(task.judge, &{&1["id"], rate(decider, task, &1, workspace)})
    general = Map.put(general, "rated", rated)
    if unavailable, do: Map.put(general, "unavailable", unavailable), else: general
  end

  @doc """
  How the decider does on the hand-written reports: `{right, asked}` over
  every question each report states an answer for.
  """
  @spec trust() :: {non_neg_integer, non_neg_integer}
  def trust do
    decider = decider()

    Path.join([@eval, "fixtures", "judge", "*.json"])
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      %{"task" => task, "report" => report, "expected" => expected} =
        path |> File.read!() |> Jason.decode!()

      state = "TASK:\n#{task}\n\nFINAL REPORT TO THE PERSON:\n#{report}"

      questions =
        Map.new(expected, fn {id, _want} ->
          {id, %{type: "noul", instructions: @questions[id]}}
        end)

      {_ok, answers} = with({:error, _reason} <- decide(decider, state, questions), do: {:error, %{}})

      for {id, want} <- expected,
          do: verdict(decider, get_in(answers, [id, "noul"])) == want
    end)
    |> then(fn right? -> {Enum.count(right?, & &1), length(right?)} end)
  end

  defp rate(decider, task, judge, workspace) do
    files =
      Enum.map_join(judge["files"], "\n\n", fn name ->
        case File.read(Path.join(workspace, name)) do
          {:ok, text} -> "FILE #{name}:\n#{text}"
          {:error, _reason} -> "FILE #{name}: missing"
        end
      end)

    state = "TASK:\n#{task.instruction}\n\n#{files}"

    questions = %{
      "score" => %{type: "score", criteria: @rubric, instructions: judge["question"]}
    }

    with {:ok, answers} <- decide(decider, state, questions),
         score when is_number(score) <- get_in(answers, ["score", "score"]) do
      Float.round(score + 1.0, 2)
    else
      _unrated -> nil
    end
  end

  defp verdict(_decider, nil), do: nil
  defp verdict(%{"sure_yes" => yes}, probability) when probability >= yes, do: true
  defp verdict(%{"sure_no" => no}, probability) when probability <= no, do: false
  defp verdict(_decider, _probability), do: nil

  defp decider, do: Toml.decode_file!(Path.join(@eval, "judge.toml"))["decider"]

  defp decide(decider, state, questions) do
    key =
      :crypto.hash(:sha256, Jason.encode!([decider["model"], state, questions]))
      |> Base.encode16(case: :lower)

    case cached(key) do
      nil ->
        with {:ok, answers} <-
               post(decider, %{model: decider["model"], state: state, questions: questions}) do
          keep(key, answers)
          {:ok, answers}
        end

      answers ->
        {:ok, answers}
    end
  end

  # A call that keeps failing says why: the decider was unavailable, which
  # is no verdict either way.
  defp post(decider, body, attempt \\ 1) do
    case Req.post(decider["url"],
           json: body,
           auth: {:bearer, System.fetch_env!(decider["key_env"])},
           receive_timeout: 120_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"answers" => answers}}} ->
        {:ok, answers}

      _failed when attempt < 5 ->
        Process.sleep(1000 * Integer.pow(2, attempt))
        post(decider, body, attempt + 1)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{body |> inspect() |> String.slice(0, 200)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp cached(key) do
    if File.exists?(@cache) do
      @cache
      |> File.stream!()
      |> Enum.find_value(fn line ->
        case Jason.decode!(line) do
          %{"key" => ^key, "answers" => answers} -> answers
          _other -> nil
        end
      end)
    end
  end

  defp keep(key, answers) do
    File.mkdir_p!(Path.dirname(@cache))
    File.write!(@cache, Jason.encode!(%{key: key, answers: answers}) <> "\n", [:append])
  end
end
