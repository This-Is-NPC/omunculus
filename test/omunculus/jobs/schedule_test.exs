defmodule Omunculus.Jobs.ScheduleTest do
  use ExUnit.Case, async: true

  alias Omunculus.Jobs.Schedule

  defp schedule(text, zone \\ "UTC") do
    {:ok, schedule} = Schedule.parse(text, zone)
    schedule
  end

  defp fires(text, zone, count, from) do
    text
    |> schedule(zone)
    |> Schedule.next_fires(count, DateTime.from_iso8601(from) |> elem(1))
    |> Enum.map(&DateTime.to_iso8601/1)
  end

  test "cron fires on the minutes, hours and days it lists" do
    assert fires("30 9 * * 1-5", "UTC", 3, "2026-11-13T10:00:00Z") ==
             ["2026-11-16T09:30:00Z", "2026-11-17T09:30:00Z", "2026-11-18T09:30:00Z"]

    assert fires("*/20 8 1 * *", "UTC", 4, "2026-11-13T10:00:00Z") ==
             [
               "2026-12-01T08:00:00Z",
               "2026-12-01T08:20:00Z",
               "2026-12-01T08:40:00Z",
               "2027-01-01T08:00:00Z"
             ]
  end

  test "a restricted day of month and day of week match either" do
    assert fires("0 0 13 * 0", "UTC", 3, "2026-11-12T00:00:00Z") ==
             ["2026-11-13T00:00:00Z", "2026-11-15T00:00:00Z", "2026-11-22T00:00:00Z"]
  end

  test "7 is Sunday" do
    assert fires("0 12 * * 7", "UTC", 1, "2026-11-13T00:00:00Z") == ["2026-11-15T12:00:00Z"]
  end

  test "every Nm and every Nh count from the start" do
    assert fires("every 90m", "UTC", 2, "2026-11-13T10:00:00Z") ==
             ["2026-11-13T11:30:00Z", "2026-11-13T13:00:00Z"]

    assert fires("every 2h", "UTC", 1, "2026-11-13T10:00:00Z") == ["2026-11-13T12:00:00Z"]
  end

  test "daily at reads the wall clock of its zone, across daylight saving time" do
    assert fires("daily at 9:00", "America/New_York", 2, "2026-03-07T00:00:00Z") ==
             ["2026-03-07T14:00:00Z", "2026-03-08T13:00:00Z"]

    assert fires("daily at 09:00", "America/Sao_Paulo", 1, "2026-11-13T00:00:00Z") ==
             ["2026-11-13T12:00:00Z"]

    assert fires("daily at 09:00", "Asia/Kolkata", 1, "2026-11-13T00:00:00Z") ==
             ["2026-11-13T03:30:00Z"]
  end

  test "a skipped time fires after the gap and a repeated one the first time" do
    assert fires("30 2 * * *", "America/New_York", 2, "2026-03-07T12:00:00Z") ==
             ["2026-03-08T07:30:00Z", "2026-03-09T06:30:00Z"]

    assert fires("30 1 * * *", "America/New_York", 2, "2026-10-31T12:00:00Z") ==
             ["2026-11-01T05:30:00Z", "2026-11-02T06:30:00Z"]
  end

  defp written(text, zone, count, from) do
    schedule = schedule(text, zone)
    {:ok, from, _} = DateTime.from_iso8601(from)
    schedule |> Schedule.next_fires(count, from) |> Enum.map(&Schedule.iso8601(schedule, &1))
  end

  test "an instant is written with its zone's offset then, the same instant" do
    # New York leaves daylight time on 2026-11-01: -04:00 before, -05:00 after.
    assert written("daily at 18:00", "America/New_York", 3, "2026-10-30T12:00:00Z") ==
             [
               "2026-10-30T18:00:00-04:00",
               "2026-10-31T18:00:00-04:00",
               "2026-11-01T18:00:00-05:00"
             ]

    assert written("daily at 18:00", "America/Sao_Paulo", 1, "2026-11-13T12:00:00Z") ==
             ["2026-11-13T18:00:00-03:00"]

    assert written("daily at 18:00", "Asia/Kolkata", 1, "2026-11-13T12:00:00Z") ==
             ["2026-11-13T18:00:00+05:30"]

    assert written("daily at 18:00", "UTC", 1, "2026-11-13T12:00:00Z") ==
             ["2026-11-13T18:00:00+00:00"]

    schedule = schedule("daily at 18:00", "America/Sao_Paulo")
    [slot] = Schedule.next_fires(schedule, 1, ~U[2026-11-13T12:00:00Z])
    assert {:ok, ^slot, -10_800} = DateTime.from_iso8601(Schedule.iso8601(schedule, slot))
  end

  test "a southern zone changes the other way" do
    assert fires("0 12 * * *", "Australia/Sydney", 2, "2026-10-03T00:00:00Z") ==
             ["2026-10-03T02:00:00Z", "2026-10-04T01:00:00Z"]
  end

  test "next fires are strictly after the instant given" do
    assert fires("0 9 * * *", "UTC", 1, "2026-11-13T09:00:00Z") == ["2026-11-14T09:00:00Z"]
  end

  test "text that is no schedule is refused" do
    for text <- [
          "",
          "every 0m",
          "every 2d",
          "daily at 25:61",
          "* * * *",
          "61 * * * *",
          "*/0 * * * *",
          "a b c d e",
          "5-1 * * * *"
        ] do
      assert match?({:error, _}, Schedule.parse(text, "UTC")), text
    end

    assert {:error, {:unknown_timezone, "Mars/Base"}} = Schedule.parse("every 1h", "Mars/Base")

    assert {:error, {:unknown_timezone, "../etc/passwd"}} =
             Schedule.parse("every 1h", "../etc/passwd")
  end

  test "min_interval is the shortest gap among the next fires" do
    assert Schedule.min_interval(schedule("every 5m")) == 300
    assert Schedule.min_interval(schedule("0,10 * * * *")) == 600
    assert Schedule.min_interval(schedule("0 9 * * 1")) == 7 * 86_400
  end
end
