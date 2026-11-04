defmodule Omunculus.GuiTimeTest do
  use ExUnit.Case, async: true

  # Sao Paulo is UTC-3 all year since 2019.
  test "stamps read in the local time zone" do
    script = """
    const now = Date.parse("2026-11-03T12:00:00Z");
    const check = (got, want) => { if (got !== want) throw Error(got + " != " + want); };
    check(Time.clock("2026-11-03T00:59:07.123Z", now), "Yesterday 21:59");
    check(Time.clock("2026-11-03T10:05:00Z", now), "07:05");
    check(Time.clock("2026-11-02T20:00:00Z", now), "Yesterday 17:00");
    check(Time.clock("2026-10-31T03:30:00Z", now), "31 Oct 00:30");
    check(Time.day("2026-11-03T15:00:00Z", now), "Today");
    check(Time.day("2026-11-03T02:59:59Z", now), "Yesterday");
    check(Time.day("2026-11-03T03:00:00Z", now), "Today");
    check(Time.day("2026-09-03T12:00:00Z", now), "03 Sep");
    check(Time.began("2026-11-04T00:59:00Z", Date.parse("2026-11-04T12:00:00Z")), "Yesterday 21:59");
    check(Time.began("2026-11-03T20:59:00Z", now), "Today 17:59");
    check(Time.began("2026-11-01T00:59:00Z", now), "31 Oct 21:59");
    check(Time.precise("2026-11-03T00:59:07.123Z"), "21:59:07.123");
    check(Time.precise("2026-11-03T12:00:00Z"), "09:00:00.000");
    check(Time.full("2026-11-03T00:59:07.123Z"), "02 Nov 2026 21:59:07.123");
    """

    assert {"", 0} =
             Omunculus.GuiModules.run(["Time"], script, [{"TZ", "America/Sao_Paulo"}])
  end
end
