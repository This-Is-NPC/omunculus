defmodule Omunculus.Jobs.Zone do
  @moduledoc """
  Time zones from the host's IANA database (`/usr/share/zoneinfo`, TZif
  version 2 or later), enough to turn a UTC instant into a zone's offset
  and a zone's wall-clock time into a UTC instant. The mix project carries
  no time zone dependency: the host's `tzdata` is the single source, and an
  unknown zone is an error, never UTC. A zone is read once and kept.

  Past its last recorded transition a zone follows the POSIX rule that ends
  its file (`M<month>.<week>.<day>` rules, the form every current zone
  uses).
  """

  @dir "/usr/share/zoneinfo"
  @epoch ~D[1970-01-01]
  @rule ~r/^(?:<[^>]+>|[A-Za-z]+)([+-]?[\d:]+)(?:(?:<[^>]+>|[A-Za-z]+)([+-]?[\d:]+)?(?:,M(\d+)\.(\d+)\.(\d+)(?:\/([+-]?[\d:]+))?,M(\d+)\.(\d+)\.(\d+)(?:\/([+-]?[\d:]+))?)?)?$/

  @type zone :: %{times: tuple, types: tuple, indexes: tuple, rule: term}

  @doc "The zone `name`, as the host's database holds it."
  @spec load(String.t()) :: {:ok, zone} | {:error, :unknown}
  def load(name) when is_binary(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil -> read(name, key)
      zone -> {:ok, zone}
    end
  end

  defp read(name, key) do
    path = Path.join(@dir, name)

    with true <- name =~ ~r/^[A-Za-z0-9_+\-\/]+$/ and not String.contains?(name, ".."),
         {:ok, binary} <- File.read(path),
         {:ok, zone} <- parse(binary) do
      :persistent_term.put(key, zone)
      {:ok, zone}
    else
      _ -> {:error, :unknown}
    end
  end

  @doc "The UTC offset in seconds of `zone` at the Unix time `unix`."
  @spec offset(zone, integer) :: integer
  def offset(%{times: times, types: types, indexes: indexes, rule: rule}, unix) do
    count = tuple_size(times)

    cond do
      count == 0 and rule == nil -> elem(types, 0).utoff
      count == 0 or (unix >= elem(times, count - 1) and rule != nil) -> rule_offset(rule, unix)
      unix < elem(times, 0) -> elem(types, 0).utoff
      true -> elem(types, elem(indexes, search(times, unix, 0, count - 1))).utoff
    end
  end

  @doc "The wall-clock time `zone` shows at the UTC instant `utc`."
  @spec to_local(zone, DateTime.t()) :: NaiveDateTime.t()
  def to_local(zone, utc) do
    unix = DateTime.to_unix(utc)
    unix |> Kernel.+(offset(zone, unix)) |> DateTime.from_unix!() |> DateTime.to_naive()
  end

  @doc """
  The UTC instant of a wall-clock time. A time shown twice, as clocks go
  back, is the earlier one; a time skipped, as clocks go forward, is read
  with the offset before the change, so it falls after the gap.
  """
  @spec to_utc(zone, NaiveDateTime.t()) :: DateTime.t()
  def to_utc(zone, naive) do
    wall = naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
    before = offset(zone, wall - 86_400)
    later = offset(zone, wall + 86_400)

    valid =
      [before, later]
      |> Enum.uniq()
      |> Enum.filter(&(offset(zone, wall - &1) == &1))

    unix =
      case valid do
        [] -> wall - before
        offsets -> wall - Enum.max(offsets)
      end

    DateTime.from_unix!(unix)
  end

  defp search(_times, _unix, low, high) when low >= high, do: low

  defp search(times, unix, low, high) do
    middle = div(low + high + 1, 2)

    if elem(times, middle) <= unix,
      do: search(times, unix, middle, high),
      else: search(times, unix, low, middle - 1)
  end

  defp parse(<<"TZif", version, _::binary-size(15), counts::binary-size(24), rest::binary>>)
       when version >= ?2 do
    skip = block(counts, 4, 8)

    <<_::binary-size(skip), "TZif", _::binary-size(16), counts::binary-size(24), rest::binary>> =
      rest

    <<_utc::32, _std::32, leap::32, timecnt::32, typecnt::32, charcnt::32>> = counts

    <<times::binary-size(timecnt * 8), indexes::binary-size(timecnt),
      types::binary-size(typecnt * 6), _::binary-size(charcnt + leap * 12), _::binary>> = rest

    footer = rest |> String.split("\n") |> Enum.at(-2)

    {:ok,
     %{
       times: for(<<time::signed-64 <- times>>, do: time) |> List.to_tuple(),
       indexes: :binary.bin_to_list(indexes) |> List.to_tuple(),
       types:
         for(<<utoff::signed-32, _dst, _abbr <- types>>, do: %{utoff: utoff}) |> List.to_tuple(),
       rule: rule(footer)
     }}
  rescue
    _ -> :error
  end

  defp parse(_binary), do: :error

  defp block(counts, time, leap) do
    <<utc::32, std::32, leaps::32, timecnt::32, typecnt::32, charcnt::32>> = counts
    timecnt * time + timecnt + typecnt * 6 + charcnt + leaps * leap + std + utc
  end

  # A footer with no daylight rule is a fixed offset; nothing follows it.
  defp rule(footer) do
    case Regex.run(@rule, footer || "") do
      [_, std] ->
        {:fixed, -seconds(std)}

      [_, std, _dst] ->
        {:fixed, -seconds(std)}

      [_, std, dst, m1, w1, d1, t1, m2, w2, d2, t2] ->
        std = -seconds(std)
        dst = if dst == "", do: std + 3600, else: -seconds(dst)

        {:dst, std, dst, {int(m1), int(w1), int(d1), time(t1)},
         {int(m2), int(w2), int(d2), time(t2)}}

      _ ->
        nil
    end
  end

  defp int(text), do: String.to_integer(text)
  defp time(""), do: 7200
  defp time(text), do: seconds(text)

  defp seconds("-" <> text), do: -seconds(text)
  defp seconds("+" <> text), do: seconds(text)

  defp seconds(text) do
    [hours | rest] = String.split(text, ":")
    parts = Enum.map(rest, &String.to_integer/1) ++ [0, 0]
    String.to_integer(hours) * 3600 + Enum.at(parts, 0) * 60 + Enum.at(parts, 1)
  end

  defp rule_offset({:fixed, offset}, _unix), do: offset

  defp rule_offset({:dst, std, dst, start, finish}, unix) do
    year = DateTime.from_unix!(unix + std).year
    starts = rule_time(year, start) - std
    ends = rule_time(year, finish) - dst

    in_dst =
      if starts < ends, do: unix >= starts and unix < ends, else: unix >= starts or unix < ends

    if in_dst, do: dst, else: std
  end

  # The wall-clock second of the `week`th `weekday` of `month`, week 5 being the last.
  defp rule_time(year, {month, week, weekday, time}) do
    first = Date.new!(year, month, 1)
    first_weekday = Date.day_of_week(first, :sunday) - 1
    day = 1 + rem(weekday - first_weekday + 7, 7) + (week - 1) * 7
    day = if day > Date.days_in_month(first), do: day - 7, else: day
    Date.diff(Date.new!(year, month, day), @epoch) * 86_400 + time
  end
end
