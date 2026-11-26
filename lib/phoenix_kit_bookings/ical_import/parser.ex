defmodule PhoenixKitBookings.ICalImport.Parser do
  @moduledoc """
  A small RFC 5545 reader for the one thing the import needs: when each
  VEVENT of a feed is busy.

  ## Why not a Hex parser

  The ones on Hex either parse without expanding RRULEs (so a weekly
  recurring block would import as its first week only) or pull in Timex for
  zone handling, when core already ships `tz`. Busy-time import needs a
  narrow, predictable subset, so it lives here and its limits are written
  down.

  ## What it handles

  - Line unfolding (CRLF or LF, space or tab continuation), property
    parameters, quoted parameter values, escaped text (`\\n`, `\\,`, `\;`).
  - `DTSTART` / `DTEND` / `DURATION` as UTC (`…Z`), zoned (`TZID=` an IANA
    id, resolved through `tz` at each instant so daylight saving is right),
    floating (read in the site zone) or all-day (`VALUE=DATE`). A missing
    end is one day for an all-day event and zero length otherwise (skipped).
  - `STATUS:CANCELLED` and `TRANSP:TRANSPARENT` events are not busy and are
    left out.
  - `RRULE` with `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, `INTERVAL`, `COUNT`,
    `UNTIL`, and `BYDAY` (plain weekdays) on weekly rules; `EXDATE`; and
    `RECURRENCE-ID` overrides (the moved instance replaces the original; a
    cancelled or transparent override just removes it). Weeks start on
    `WKST`. Occurrences are generated in the event's own wall clock and
    expanded only inside the requested window.
  - A body without both `BEGIN:VCALENDAR` and `END:VCALENDAR` (a page, or a
    feed cut off in transit) is `{:error, :not_a_calendar}`, as is one the
    reader trips over; a feed expanding to more than 20 000 occurrences in
    the window is `{:error, :too_many_events}`. Neither imports anything,
    so neither deletes what an earlier sync imported.

  ## Limits

  - Other RRULE parts (`BYSETPOS`, `BYMONTHDAY` lists, ordinal `BYDAY` such
    as `2MO`, `BYHOUR`, `BYWEEKNO`, …) are not expanded: such an event
    imports its first occurrence only, and is counted in `:unsupported`.
  - A `TZID` that is not an IANA id (Outlook's "FLE Standard Time") is read
    in the site zone; the feed's own `VTIMEZONE` blocks are not interpreted.
  - `RDATE` is ignored.

  `parse/2` returns `{:ok, %{events: [occurrence], unsupported: n}}` where
  an occurrence is `%{uid, summary, recurrence_id?, range}` and `range` is
  `{:datetime, starts_utc, ends_utc}` or `{:date, first_day, day_after_last}`.
  """

  @max_occurrences 2_000
  # Occurrences a whole feed may expand to; more is refused, not truncated,
  # because a truncated list would delete the imported rows past the cut.
  @max_feed_occurrences 20_000
  # The longest event read (a century): date arithmetic on a DURATION of
  # 10^20 seconds runs for minutes, so a longer one is cut to this.
  @max_length_seconds 100 * 366 * 86_400
  # Candidates walked per rule at most (a daily rule over 270 years).
  @max_steps 100_000

  @weekdays %{"MO" => 1, "TU" => 2, "WE" => 3, "TH" => 4, "FR" => 5, "SA" => 6, "SU" => 7}

  @doc """
  Parses a feed. Options:

  - `:from` / `:until` (`DateTime`, required) — the window occurrences are
    expanded in (an occurrence is kept when it overlaps it).
  - `:tz` — the zone floating times and unknown TZIDs are read in
    (default `"Etc/UTC"`).
  """
  def parse(text, opts) when is_binary(text) do
    from = Keyword.fetch!(opts, :from)
    until = Keyword.fetch!(opts, :until)
    tz = Keyword.get(opts, :tz, "Etc/UTC")

    lines = text |> String.trim_leading("\uFEFF") |> unfold()

    # A body cut off in transit still starts like a calendar; read as one it
    # would list fewer events, and the sync would delete the missing ones.
    # Judged on whole (unfolded) lines, so a value cannot fake the end.
    if envelope?(lines, "BEGIN:VCALENDAR") and envelope?(lines, "END:VCALENDAR") do
      do_parse(lines, from, until, tz)
    else
      {:error, :not_a_calendar}
    end
  end

  defp envelope?(lines, marker),
    do: Enum.any?(lines, &(&1 |> String.trim() |> String.upcase() == marker))

  defp do_parse(lines, from, until, tz) do
    {events, unsupported} =
      lines
      |> Enum.map(&parse_line/1)
      |> Enum.reject(&is_nil/1)
      |> vevents()
      |> Enum.map(&to_event(&1, tz))
      |> Enum.reject(&is_nil/1)
      |> expand_all(from, until)

    if length(events) > @max_feed_occurrences,
      do: {:error, :too_many_events},
      else: {:ok, %{events: events, unsupported: unsupported}}
  rescue
    # Whatever a malformed feed trips (a date past year 9999, …) is a feed
    # that cannot be read, not a crash of the sync.
    _ -> {:error, :not_a_calendar}
  end

  # ── Lexing ───────────────────────────────────────────────────────────

  defp unfold(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/\n[ \t]/, "")
    |> String.split("\n", trim: true)
  end

  # NAME;PARAM=VALUE;PARAM="V:A;L":value — the first colon outside quotes
  # ends the name and its parameters.
  defp parse_line(line) do
    case split_value(line) do
      {head, value} ->
        [name | params] = split_params(head)
        name = String.upcase(name)
        value = if name in ["BEGIN", "END"], do: String.upcase(String.trim(value)), else: value
        {name, parse_params(params), value}

      nil ->
        nil
    end
  end

  defp split_value(line), do: split_value(line, "", false)

  defp split_value(<<"\"", rest::binary>>, acc, quoted),
    do: split_value(rest, acc <> "\"", not quoted)

  defp split_value(<<":", rest::binary>>, acc, false), do: {acc, rest}

  defp split_value(<<c::utf8, rest::binary>>, acc, quoted),
    do: split_value(rest, acc <> <<c::utf8>>, quoted)

  defp split_value(<<_byte, rest::binary>>, acc, quoted), do: split_value(rest, acc, quoted)
  defp split_value("", _acc, _quoted), do: nil

  defp split_params(head) do
    ~r/;(?=(?:[^"]*"[^"]*")*[^"]*$)/
    |> Regex.split(head)
  end

  defp parse_params(params) do
    Map.new(params, fn param ->
      case String.split(param, "=", parts: 2) do
        [k, v] -> {String.upcase(k), String.trim(v, "\"")}
        [k] -> {String.upcase(k), ""}
      end
    end)
  end

  # The property lists of top-level VEVENTs (nested VALARMs dropped).
  defp vevents(lines) do
    {events, _current, _depth} =
      Enum.reduce(lines, {[], nil, 0}, fn
        {"BEGIN", _, "VEVENT"}, {events, nil, 0} ->
          {events, [], 0}

        {"BEGIN", _, _other}, {events, current, depth} when is_list(current) ->
          {events, current, depth + 1}

        {"END", _, "VEVENT"}, {events, current, 0} when is_list(current) ->
          {[Enum.reverse(current) | events], nil, 0}

        {"END", _, _other}, {events, current, depth} when is_list(current) and depth > 0 ->
          {events, current, depth - 1}

        prop, {events, current, 0} when is_list(current) ->
          {events, [prop | current], 0}

        _prop, acc ->
          acc
      end)

    Enum.reverse(events)
  end

  # ── One VEVENT ───────────────────────────────────────────────────────

  defp to_event(props, tz) do
    get = fn name -> Enum.find(props, &(elem(&1, 0) == name)) end

    with {_, _, uid} <- get.("UID") || {nil, nil, nil},
         false <- is_nil(uid) or uid == "",
         {_, start_params, start_value} <- get.("DTSTART"),
         {:ok, start} <- parse_time(start_value, start_params, tz) do
      %{
        uid: uid,
        busy?: not busy_free?(get),
        summary: get_text(get.("SUMMARY")),
        start: start,
        length: event_length(start, get.("DTEND"), get.("DURATION"), tz),
        rrule: get_value(get.("RRULE")),
        exdates: exdates(props, tz),
        recurrence_id: recurrence_id(get.("RECURRENCE-ID"), tz)
      }
    else
      _ -> nil
    end
  end

  defp busy_free?(get) do
    status = get_value(get.("STATUS"))
    transp = get_value(get.("TRANSP"))
    upcase(status) == "CANCELLED" or upcase(transp) == "TRANSPARENT"
  end

  defp upcase(nil), do: nil
  defp upcase(value), do: String.upcase(String.trim(value))

  defp get_value({_, _, value}), do: value
  defp get_value(_), do: nil

  # One pass, so the `\\` of `C:\\new` is a backslash and not half of `\n`.
  defp get_text({_, _, value}) do
    Regex.replace(~r/\\([\\;,nN])/, value, fn
      _, c when c in ["n", "N"] -> "\n"
      _, c -> c
    end)
  end

  defp get_text(_), do: nil

  defp exdates(props, tz) do
    for {"EXDATE", params, value} <- props,
        part <- String.split(value, ","),
        {:ok, time} <- [parse_time(part, params, tz)],
        do: time
  end

  defp recurrence_id(nil, _tz), do: nil

  defp recurrence_id({_, params, value}, tz) do
    case parse_time(value, params, tz) do
      {:ok, time} -> time
      _ -> nil
    end
  end

  # A start is `{:date, date}` or `{:local, naive, zone}` (zone nil = UTC);
  # the zone stays attached so recurrences step in wall-clock time.
  defp parse_time(value, params, tz) do
    value = String.trim(value)

    cond do
      params["VALUE"] == "DATE" or Regex.match?(~r/^\d{8}$/, value) ->
        with {:ok, date} <- parse_date(value), do: {:ok, {:date, date}}

      String.ends_with?(value, "Z") ->
        with {:ok, naive} <- parse_naive(String.trim_trailing(value, "Z")),
             do: {:ok, {:local, naive, "Etc/UTC"}}

      true ->
        with {:ok, naive} <- parse_naive(value),
             do: {:ok, {:local, naive, known_zone(params["TZID"], tz)}}
    end
  end

  defp known_zone(nil, tz), do: tz

  defp known_zone(tzid, tz) do
    tzid = String.trim_leading(tzid, "/")

    case DateTime.from_naive(~N[2000-01-01 00:00:00], tzid, Tz.TimeZoneDatabase) do
      {:ok, _} -> tzid
      _ -> tz
    end
  end

  defp parse_date(<<y::binary-4, m::binary-2, d::binary-2, _::binary>>) do
    with {y, ""} <- Integer.parse(y),
         {m, ""} <- Integer.parse(m),
         {d, ""} <- Integer.parse(d) do
      Date.new(y, m, d)
    else
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp parse_naive(<<date::binary-8, "T", h::binary-2, mi::binary-2, s::binary-2, _::binary>>) do
    with {:ok, date} <- parse_date(date),
         {h, ""} <- Integer.parse(h),
         {mi, ""} <- Integer.parse(mi),
         {s, ""} <- Integer.parse(s),
         {:ok, time} <- Time.new(h, mi, min(s, 59)) do
      {:ok, NaiveDateTime.new!(date, time)}
    else
      _ -> :error
    end
  end

  defp parse_naive(_), do: :error

  # Length as `{:days, n}` (all-day) or `{:seconds, n}`.
  defp event_length({:date, start}, dtend, duration, tz) do
    cond do
      dtend ->
        case parse_time(elem(dtend, 2), elem(dtend, 1), tz) do
          {:ok, {:date, finish}} -> {:days, max(Date.diff(finish, start), 1)}
          _ -> {:days, 1}
        end

      duration ->
        {:days, max(div(parse_duration(elem(duration, 2)), 86_400), 1)}

      true ->
        {:days, 1}
    end
  end

  defp event_length({:local, naive, zone}, dtend, duration, tz) do
    cond do
      dtend ->
        case parse_time(elem(dtend, 2), elem(dtend, 1), tz) do
          {:ok, {:local, _, _} = finish} ->
            {:seconds, DateTime.diff(to_utc(finish), to_utc({:local, naive, zone}))}

          _ ->
            {:seconds, 0}
        end

      duration ->
        {:seconds, parse_duration(elem(duration, 2))}

      true ->
        {:seconds, 0}
    end
  end

  # ISO-8601 duration as RFC 5545 writes it: [+-]P[nW][nD][T[nH][nM][nS]].
  defp parse_duration(value) do
    case Regex.run(
           ~r/^[+-]?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/,
           String.trim(value)
         ) do
      [_ | parts] ->
        [w, d, h, m, s] = Enum.map(parts ++ List.duplicate("", 5 - length(parts)), &to_int/1)
        seconds = w * 604_800 + d * 86_400 + h * 3600 + m * 60 + s
        min(seconds, @max_length_seconds)

      _ ->
        0
    end
  end

  defp to_int(""), do: 0
  defp to_int(value), do: String.to_integer(value)

  # ── Recurrence ───────────────────────────────────────────────────────

  defp expand_all(events, from, until) do
    {masters, overrides} = Enum.split_with(events, &is_nil(&1.recurrence_id))

    # A RECURRENCE-ID instance replaces the master's occurrence at that time,
    # also when the override is cancelled or transparent (then it is just gone).
    moved = MapSet.new(overrides, &{&1.uid, instant_key(&1.recurrence_id)})
    masters = Enum.filter(masters, & &1.busy?)
    overrides = Enum.filter(overrides, & &1.busy?)

    {occurrences, unsupported} =
      Enum.reduce(masters, {[], 0}, fn event, {acc, unsupported} ->
        {starts, supported?} = occurrence_starts(event, from, until)
        excluded = MapSet.new(event.exdates, &instant_key/1)

        kept =
          starts
          |> Enum.reject(fn start ->
            key = instant_key(start)
            MapSet.member?(excluded, key) or MapSet.member?(moved, {event.uid, key})
          end)
          |> Enum.map(&occurrence(event, &1, event.rrule != nil))

        {kept ++ acc, if(supported?, do: unsupported, else: unsupported + 1)}
      end)

    override_occurrences =
      Enum.map(overrides, fn event ->
        event |> occurrence(event.start, true) |> Map.put(:recurrence_id, event.recurrence_id)
      end)

    events =
      (occurrences ++ override_occurrences)
      |> Enum.reject(&is_nil(&1.range))
      |> Enum.filter(&overlaps?(&1.range, from, until))
      |> Enum.sort_by(&range_sort_key/1)

    {events, unsupported}
  end

  defp occurrence(event, start, recurring?) do
    %{
      uid: event.uid,
      summary: event.summary,
      recurrence_id: if(recurring?, do: start),
      range: range(start, event.length)
    }
  end

  defp range({:date, date}, {:days, n}), do: {:date, date, Date.add(date, n)}

  defp range({:local, _, _} = start, {:seconds, n}) when n > 0 do
    starts = to_utc(start)
    {:datetime, starts, DateTime.add(starts, n, :second)}
  end

  defp range(_start, _length), do: nil

  defp overlaps?({:date, first, after_last}, from, until) do
    Date.compare(after_last, DateTime.to_date(from)) == :gt and
      Date.compare(first, DateTime.to_date(until)) != :gt
  end

  defp overlaps?({:datetime, starts, ends}, from, until) do
    DateTime.compare(ends, from) == :gt and DateTime.compare(starts, until) == :lt
  end

  defp range_sort_key(%{range: {:date, d, _}}), do: Date.to_iso8601(d)
  defp range_sort_key(%{range: {:datetime, s, _}}), do: DateTime.to_iso8601(s)

  # Starts of every occurrence up to `until`, and whether the rule was fully
  # understood (an unsupported rule yields its first occurrence only).
  defp occurrence_starts(%{rrule: nil, start: start}, _from, _until), do: {[start], true}

  defp occurrence_starts(%{rrule: rrule, start: start, length: length}, from, until) do
    rule = parse_rrule(rrule)

    if supported_rule?(rule) do
      {generate(rule, start, length, from, until), true}
    else
      {[start], false}
    end
  end

  defp parse_rrule(rrule) do
    rrule
    |> String.split(";", trim: true)
    |> Map.new(fn part ->
      case String.split(part, "=", parts: 2) do
        [k, v] -> {String.upcase(k), String.upcase(v)}
        [k] -> {String.upcase(k), ""}
      end
    end)
  end

  @supported_parts ~w(FREQ INTERVAL COUNT UNTIL BYDAY WKST)

  defp supported_rule?(rule) do
    Map.get(rule, "FREQ") in ~w(DAILY WEEKLY MONTHLY YEARLY) and
      Enum.all?(Map.keys(rule), &(&1 in @supported_parts)) and
      byday_supported?(rule)
  end

  # Plain weekdays, on weekly rules only.
  defp byday_supported?(%{"BYDAY" => days, "FREQ" => "WEEKLY"}),
    do: days |> String.split(",") |> Enum.all?(&Map.has_key?(@weekdays, &1))

  defp byday_supported?(%{"BYDAY" => _}), do: false
  defp byday_supported?(_), do: true

  # COUNT counts from DTSTART, so a counted rule is walked from the start; an
  # open-ended one skips what ends before the window without counting it,
  # or a daily rule from years ago would spend its budget in the past.
  defp generate(rule, start, length, from, until) do
    interval = rule |> Map.get("INTERVAL", "1") |> Integer.parse() |> elem_or(1) |> max(1)
    count = rule |> Map.get("COUNT") |> parse_count()
    rule_until = rule |> Map.get("UNTIL") |> parse_until(start)
    earliest = Date.add(DateTime.to_date(from), -length_days(length) - 1)

    stream =
      start
      |> candidates(rule, interval)
      |> Stream.take(@max_steps)
      |> Stream.take_while(fn candidate ->
        before_or_at?(candidate, rule_until) and starts_before?(candidate, until)
      end)

    case count do
      nil ->
        stream
        |> Stream.reject(&(Date.compare(start_date(&1), earliest) == :lt))
        |> Enum.take(@max_occurrences)

      count ->
        Enum.take(stream, min(count, @max_occurrences))
    end
  end

  defp length_days({:days, n}), do: n
  defp length_days({:seconds, n}), do: div(n, 86_400) + 1

  defp elem_or({value, _rest}, _default), do: value
  defp elem_or(:error, default), do: default

  defp parse_count(nil), do: nil

  defp parse_count(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_until(nil, _start), do: nil

  defp parse_until(value, start) do
    case parse_time(value, %{}, start_zone(start)) do
      {:ok, until} -> until
      _ -> nil
    end
  end

  defp start_zone({:local, _, zone}), do: zone
  defp start_zone(_), do: "Etc/UTC"

  # Every candidate start in order, from DTSTART on.
  # Weeks begin on WKST (Monday by default), which matters once INTERVAL > 1.
  defp candidates(start, %{"FREQ" => "WEEKLY", "BYDAY" => days} = rule, interval) do
    wkst = Map.get(@weekdays, Map.get(rule, "WKST", "MO"), 1)

    offsets =
      days |> String.split(",") |> Enum.map(&Integer.mod(@weekdays[&1] - wkst, 7)) |> Enum.sort()

    first_date = start_date(start)
    week_start = Date.add(first_date, -Integer.mod(Date.day_of_week(first_date) - wkst, 7))

    Stream.iterate(0, &(&1 + 1))
    |> Stream.flat_map(fn week ->
      first = Date.add(week_start, week * 7 * interval)
      Enum.map(offsets, &with_date(start, Date.add(first, &1)))
    end)
    |> Stream.reject(&(Date.compare(start_date(&1), first_date) == :lt))
  end

  defp candidates(start, %{"FREQ" => freq}, interval) do
    first_date = start_date(start)

    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(fn n -> step_date(first_date, freq, n * interval) end)
    |> Stream.reject(&is_nil/1)
    |> Stream.map(&with_date(start, &1))
  end

  defp step_date(date, "DAILY", n), do: Date.add(date, n)
  defp step_date(date, "WEEKLY", n), do: Date.add(date, 7 * n)
  defp step_date(date, "MONTHLY", n), do: shift_months(date, n)
  defp step_date(date, "YEARLY", n), do: shift_months(date, 12 * n)

  # A month without the start's day (the 31st, 29 February) has no
  # occurrence, as RFC 5545 says.
  defp shift_months(%Date{year: y, month: m, day: d}, n) do
    total = y * 12 + (m - 1) + n
    year = div(total, 12)
    month = rem(total, 12) + 1

    case Date.new(year, month, d) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp start_date({:date, date}), do: date
  defp start_date({:local, naive, _zone}), do: NaiveDateTime.to_date(naive)

  defp with_date({:date, _}, date), do: {:date, date}

  defp with_date({:local, naive, zone}, date),
    do: {:local, NaiveDateTime.new!(date, NaiveDateTime.to_time(naive)), zone}

  defp before_or_at?(_candidate, nil), do: true

  defp before_or_at?(candidate, until),
    do: compare_key(instant_key(candidate), instant_key(until)) != :gt

  defp starts_before?({:date, date}, until),
    do: Date.compare(date, DateTime.to_date(until)) != :gt

  defp starts_before?(candidate, until), do: DateTime.compare(to_utc(candidate), until) == :lt

  defp compare_key({:date, a}, {:date, b}), do: Date.compare(a, b)
  defp compare_key({:date, a}, {:utc, b}), do: Date.compare(a, DateTime.to_date(b))
  defp compare_key({:utc, a}, {:date, b}), do: Date.compare(DateTime.to_date(a), b)
  defp compare_key({:utc, a}, {:utc, b}), do: DateTime.compare(a, b)

  # Comparable identity of an instant: a date stays a date, a time is UTC.
  defp instant_key({:date, date}), do: {:date, date}
  defp instant_key({:local, _, _} = time), do: {:utc, to_utc(time)}

  # A wall clock in its zone, resolved at that instant. A clock inside a gap
  # (spring forward) is read with the offset before the gap, as RFC 5545
  # §3.3.5 says; an ambiguous hour takes its first occurrence.
  defp to_utc({:local, naive, zone}) do
    case DateTime.from_naive(naive, zone, Tz.TimeZoneDatabase) do
      {:ok, dt} ->
        DateTime.shift_zone!(dt, "Etc/UTC", Tz.TimeZoneDatabase)

      {:ambiguous, first, _second} ->
        DateTime.shift_zone!(first, "Etc/UTC", Tz.TimeZoneDatabase)

      {:gap, before, _after} ->
        naive
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.add(-(before.utc_offset + before.std_offset), :second)

      {:error, _} ->
        DateTime.from_naive!(naive, "Etc/UTC")
    end
  end
end
