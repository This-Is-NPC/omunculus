defmodule Omunculus.Jobs.Schedule do
  @moduledoc """
  A job's schedule, read from text and a time zone, and the instants it
  fires at. Three forms are understood, all in the zone given:

  - a 5-field cron expression, `minute hour day-of-month month day-of-week`:
    each field is `*`, a number, a range `a-b`, a step `*/n` or `a-b/n`, or
    a comma list of those; days of the week run 0-7 with 0 and 7 Sunday; when
    both day fields are restricted a day matches either, as cron does;
  - `every Nm` or `every Nh`: a fixed interval, counted from the instant
    the schedule starts;
  - `daily at HH:MM`.

  A time the zone skips (clocks going forward) fires just after the gap; one
  it shows twice fires the first time (`Omunculus.Jobs.Zone`).

  The parser is small and owned here, rather than a dependency, because the
  grammar is this short and the host's own time zone database
  (`Omunculus.Jobs.Zone`) is the one source of zones.
  """

  alias Omunculus.Jobs.Zone

  @enforce_keys [:text, :timezone, :zone, :kind]
  defstruct [:text, :timezone, :zone, :kind]

  @type t :: %__MODULE__{
          text: String.t(),
          timezone: String.t(),
          zone: Zone.zone(),
          kind: {:every, pos_integer} | {:cron, map}
        }

  @fields [minute: {0, 59}, hour: {0, 23}, day: {1, 31}, month: {1, 12}, weekday: {0, 7}]
  # Days looked through for the next match: a rule that never matches ends there.
  @horizon_days 366 * 8
  @sample 50

  @spec parse(String.t(), String.t()) :: {:ok, t} | {:error, term}
  def parse(text, timezone) when is_binary(text) and is_binary(timezone) do
    with {:ok, zone} <- zone(timezone),
         {:ok, kind} <- kind(String.trim(text)) do
      {:ok, %__MODULE__{text: String.trim(text), timezone: timezone, zone: zone, kind: kind}}
    end
  end

  def parse(_text, _timezone), do: {:error, :invalid_schedule}

  defp zone(timezone) do
    case Zone.load(timezone) do
      {:ok, zone} -> {:ok, zone}
      {:error, :unknown} -> {:error, {:unknown_timezone, timezone}}
    end
  end

  defp kind(text) do
    cond do
      match = Regex.run(~r/^every (\d+)([mh])$/, text) ->
        [_, count, unit] = match
        seconds = String.to_integer(count) * if(unit == "m", do: 60, else: 3600)
        if seconds > 0, do: {:ok, {:every, seconds}}, else: {:error, :invalid_schedule}

      match = Regex.run(~r/^daily at (\d{1,2}):(\d{2})$/, text) ->
        [_, hour, minute] = match
        cron("#{String.to_integer(minute)} #{String.to_integer(hour)} * * *")

      true ->
        cron(text)
    end
  end

  defp cron(text) do
    case String.split(text) do
      [_, _, _, _, _] = fields ->
        fields
        |> Enum.zip(@fields)
        |> Enum.reduce_while({:ok, %{}}, fn {field, {name, range}}, {:ok, acc} ->
          case field(field, range) do
            {:ok, values} -> {:cont, {:ok, Map.put(acc, name, {field == "*", values})}}
            :error -> {:halt, {:error, :invalid_schedule}}
          end
        end)
        |> case do
          {:ok, spec} -> {:ok, {:cron, normalize_weekdays(spec)}}
          error -> error
        end

      _other ->
        {:error, :invalid_schedule}
    end
  end

  defp normalize_weekdays(%{weekday: {star, days}} = spec),
    do: %{spec | weekday: {star, days |> Enum.map(&rem(&1, 7)) |> Enum.uniq() |> Enum.sort()}}

  defp field(text, range) do
    text
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case part(part, range) do
        {:ok, values} -> {:cont, {:ok, acc ++ values}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.uniq() |> Enum.sort()}
      :error -> :error
    end
  end

  defp part(part, {low, high}) do
    with {span, step, stepped} <- split_step(part),
         {:ok, first, last} <- span(span, low, high, stepped) do
      {:ok, Enum.take_every(first..last//1, step)}
    else
      _ -> :error
    end
  end

  defp split_step(part) do
    case String.split(part, "/") do
      [span] -> {span, 1, false}
      [span, step] -> if (n = number(step)) && n >= 1, do: {span, n, true}, else: :error
      _ -> :error
    end
  end

  defp span("*", low, high, _stepped), do: {:ok, low, high}

  defp span(text, low, high, stepped) do
    case Enum.map(String.split(text, "-"), &number/1) do
      [first, last] when is_integer(first) and is_integer(last) ->
        if low <= first and first <= last and last <= high, do: {:ok, first, last}, else: :error

      [first] when is_integer(first) ->
        cond do
          first < low or first > high -> :error
          stepped -> {:ok, first, high}
          true -> {:ok, first, first}
        end

      _ ->
        :error
    end
  end

  defp number(text) do
    case Integer.parse(text) do
      {value, ""} -> value
      _ -> nil
    end
  end

  @doc "An instant of the schedule as ISO 8601 with its zone's offset then."
  @spec iso8601(t, DateTime.t()) :: String.t()
  def iso8601(%__MODULE__{zone: zone}, instant), do: Zone.iso8601(zone, instant)

  @doc """
  The next `count` instants after `from` (now when left out) the schedule
  fires at, in UTC, oldest first. A rule that has no instant within eight
  years gives fewer.
  """
  @spec next_fires(t, non_neg_integer, DateTime.t()) :: [DateTime.t()]
  def next_fires(schedule, count, from \\ DateTime.utc_now())

  def next_fires(%__MODULE__{kind: {:every, seconds}}, count, from),
    do: for(step <- 1..count//1, do: DateTime.add(from, step * seconds, :second))

  def next_fires(%__MODULE__{kind: {:cron, spec}, zone: zone}, count, from) do
    start = zone |> Zone.to_local(from) |> NaiveDateTime.to_date()

    start
    |> Stream.iterate(&Date.add(&1, 1))
    |> Stream.take(@horizon_days)
    |> Stream.filter(&day?(spec, &1))
    |> Stream.flat_map(&times(spec, zone, &1))
    |> Stream.filter(&(DateTime.compare(&1, from) == :gt))
    |> Enum.take(count)
  end

  defp day?(spec, date) do
    {day_star, days} = spec.day
    {weekday_star, weekdays} = spec.weekday
    day = date.day in days
    weekday = rem(Date.day_of_week(date), 7) in weekdays
    matches = if day_star or weekday_star, do: day and weekday, else: day or weekday
    date.month in elem(spec.month, 1) and matches
  end

  defp times(spec, zone, date) do
    for hour <- elem(spec.hour, 1), minute <- elem(spec.minute, 1) do
      zone |> Zone.to_utc(NaiveDateTime.new!(date, Time.new!(hour, minute, 0)))
    end
    |> Enum.sort_by(&DateTime.to_unix/1)
  end

  @doc """
  The shortest gap in seconds between two of the next fires after `from`
  (the first `#{@sample}`), or nil for a schedule that fires fewer than
  twice. What a limit on a schedule's frequency measures.
  """
  @spec min_interval(t, DateTime.t()) :: pos_integer | nil
  def min_interval(schedule, from \\ DateTime.utc_now())
  def min_interval(%__MODULE__{kind: {:every, seconds}}, _from), do: seconds

  def min_interval(schedule, from) do
    schedule
    |> next_fires(@sample, from)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> DateTime.diff(b, a) end)
    |> Enum.min(fn -> nil end)
  end
end
