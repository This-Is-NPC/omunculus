defmodule Omunculus.Process.ActivitiesTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Process.{Activities, Log}
  alias Omunculus.ProcessFixtures
  alias Omunculus.Store

  setup %{conn: conn} do
    seeded = ProcessFixtures.seed(conn)
    {:ok, raw} = Store.log(conn, nil)
    Map.put(seeded, :log, Log.build(raw))
  end

  test "an activity has its count, mean and p90 duration, cost and refusals", %{log: log} do
    stats = Map.new(Activities.stats(log.events), &{&1.activity, &1})

    assert %{count: 11, mean: 1.0, p90: 1.0, refusals: 0} = stats["read"]
    assert %{count: 6, refusals: 1} = stats["bash"]
    assert %{count: 17, usd: usd} = stats["model reply"]
    assert_in_delta usd, 7.1, 1.0e-9
  end

  test "p90 is the nearest rank" do
    durations = for seconds <- 1..10, do: seconds * 1.0

    events =
      for seconds <- durations,
          do: %{kind: :call, activity: "a", attrs: %{"duration" => seconds, "ok" => true}}

    assert [%{mean: 5.5, p90: 9.0}] = Activities.stats(events)
  end

  test "variants fold a run of one activity and count the works of each", %{
    log: log,
    works: works
  } do
    [first | _] = variants = Activities.variants(log.works)

    assert first.sequence == [
             "enter to_do",
             "read",
             "write",
             "bash",
             "continue",
             "enter review",
             "read",
             "continue",
             "work done"
           ]

    assert Enum.sort(Enum.map(first.works, & &1.id)) ==
             Enum.sort([works.done_a, works.done_b, works.done_c])

    assert length(variants) == 6
  end
end
