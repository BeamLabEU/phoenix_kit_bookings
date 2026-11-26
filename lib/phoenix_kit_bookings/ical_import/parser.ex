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
    id, resolved through `tz` at each instant so daylight saving is right,
    or one of the feed's own `VTIMEZONE`s: fixed offsets, or STANDARD /
    DAYLIGHT observances with a yearly `BYMONTH` + ordinal `BYDAY` rule),
    floating (read in the site zone) or all-day (`VALUE=DATE`). A missing
    end is one day for an all-day event and zero length otherwise (skipped).
    The days and weeks of a `DURATION` are calendar days (`P1D` across a
    clock change is 23 or 25 hours), its time part exact.
  - `STATUS:CANCELLED` and `TRANSP:TRANSPARENT` events are not busy and are
    left out.
  - `RRULE` with `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, `INTERVAL`, `COUNT`,
    `UNTIL`, `BYDAY` (plain weekdays) on weekly rules, `BYDAY` (plain or
    ordinal: `2TU`, `-1FR`) and `BYMONTHDAY` (negative from the month's end)
    on monthly rules; `EXDATE`; and
    `RECURRENCE-ID` overrides (the moved instance replaces the original; a
    cancelled or transparent override just removes it). Weeks start on
    `WKST`. Occurrences are generated in the event's own wall clock and
    expanded only inside the requested window; an instance whose wall
    clock falls in a spring-forward gap is skipped and not counted.
  - A body without both `BEGIN:VCALENDAR` and `END:VCALENDAR` (a page, or a
    feed cut off in transit) is `{:error, :not_a_calendar}`, as is one the
    reader trips over; a feed expanding to more than 20 000 occurrences in
    the window is `{:error, :too_many_events}`. Neither imports anything,
    so neither deletes what an earlier sync imported.

  ## Limits

  - Other RRULE parts (`BYSETPOS`, `BYMONTH`, `BYHOUR`, `BYWEEKNO`, ordinal
    `BYDAY` on yearly rules, …) are not expanded: such an event imports its
    first occurrence only, and is counted in `:unsupported`.
  - A `TZID` that is neither an IANA id nor a `VTIMEZONE` of the shape above
    is read in the site zone, and its event is counted in `:unsupported`.
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
    props = lines |> Enum.map(&parse_line/1) |> Enum.reject(&is_nil/1)
    # Times are read in a context: the default zone (floating times) and the
    # feed's own VTIMEZONE definitions by TZID.
    ctx = {tz, vtimezones(props)}

    {events, unsupported} =
      props
      |> vevents()
      |> Enum.map(&to_event(&1, ctx))
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
        tz_fallback?: tz_fallback?(start_params["TZID"], tz),
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

  # A TZID is an IANA id, else one of the feed's VTIMEZONEs this reader
  # understands ({:custom, observances}), else the default zone.
  defp known_zone(nil, {zone, _vtz}), do: zone

  defp known_zone(tzid, {zone, vtz}) do
    case resolve_tzid(tzid, vtz) do
      nil -> zone
      known -> known
    end
  end

  defp resolve_tzid(tzid, vtz) do
    iana = String.trim_leading(tzid, "/")

    case DateTime.from_naive(~N[2000-01-01 00:00:00], iana, Tz.TimeZoneDatabase) do
      {:ok, _} -> iana
      _ -> Map.get(vtz, tzid)
    end
  end

  defp tz_fallback?(nil, _ctx), do: false
  defp tz_fallback?(tzid, {_zone, vtz}), do: is_nil(resolve_tzid(tzid, vtz))

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

      # Days and weeks are nominal (a calendar day, 23 or 25 hours across a
      # clock change); the time part is exact. RFC 5545 §3.3.6.
      duration ->
        {days, seconds} = parse_duration_parts(elem(duration, 2))
        if days == 0, do: {:seconds, seconds}, else: {:nominal, days, seconds}

      true ->
        {:seconds, 0}
    end
  end

  # A duration as {calendar days, exact seconds}, each within the cap.
  defp parse_duration_parts(value) do
    case Regex.run(
           ~r/^[+-]?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/,
           String.trim(value)
         ) do
      [_ | parts] ->
        [w, d, h, m, s] = Enum.map(parts ++ List.duplicate("", 5 - length(parts)), &to_int/1)
        days = min(w * 7 + d, div(@max_length_seconds, 86_400))
        {days, min(h * 3600 + m * 60 + s, @max_length_seconds)}

      _ ->
        {0, 0}
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

        counted? = supported? and not event.tz_fallback?
        {kept ++ acc, if(counted?, do: unsupported, else: unsupported + 1)}
      end)

    override_occurrences =
      Enum.map(overrides, fn event ->
        event
        |> occurrence(event.start, true)
        |> Map.put(:recurrence_id, public_instant(event.recurrence_id))
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
      recurrence_id: if(recurring?, do: public_instant(start)),
      range: range(start, event.length)
    }
  end

  defp range({:date, date}, {:days, n}), do: {:date, date, Date.add(date, n)}

  defp range({:local, _, _} = start, {:seconds, n}) when n > 0 do
    starts = to_utc(start)
    {:datetime, starts, DateTime.add(starts, n, :second)}
  end

  defp range({:local, naive, zone} = start, {:nominal, days, seconds}) do
    ends =
      {:local, NaiveDateTime.add(naive, days * 86_400, :second), zone}
      |> to_utc()
      |> DateTime.add(seconds, :second)

    {:datetime, to_utc(start), ends}
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

  @supported_parts ~w(FREQ INTERVAL COUNT UNTIL BYDAY BYMONTHDAY WKST)

  defp supported_rule?(rule) do
    Map.get(rule, "FREQ") in ~w(DAILY WEEKLY MONTHLY YEARLY) and
      Enum.all?(Map.keys(rule), &(&1 in @supported_parts)) and
      byday_supported?(rule) and monthday_supported?(rule)
  end

  # Plain weekdays on weekly rules; plain or ordinal ones (2TU, -1FR) on
  # monthly rules.
  defp byday_supported?(%{"BYDAY" => days, "FREQ" => "WEEKLY"}),
    do: days |> String.split(",") |> Enum.all?(&Map.has_key?(@weekdays, &1))

  defp byday_supported?(%{"BYDAY" => days, "FREQ" => "MONTHLY"}),
    do: days |> String.split(",") |> Enum.all?(&match?({:ok, _}, parse_byday(&1)))

  defp byday_supported?(%{"BYDAY" => _}), do: false
  defp byday_supported?(_), do: true

  # Month days (negative from the end), on monthly rules.
  defp monthday_supported?(%{"BYMONTHDAY" => days, "FREQ" => "MONTHLY"}),
    do: match?({:ok, _}, parse_monthdays(days))

  defp monthday_supported?(%{"BYMONTHDAY" => _}), do: false
  defp monthday_supported?(_), do: true

  # "2TU" -> {2, 2}, "-1FR" -> {-1, 5}, "MO" -> {nil, 1}.
  defp parse_byday(text) do
    case Regex.run(~r/^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$/, text) do
      [_, "", day] -> {:ok, {nil, @weekdays[day]}}
      [_, day_name] -> {:ok, {nil, @weekdays[day_name]}}
      [_, n, day] -> ordinal(Integer.parse(n), @weekdays[day])
      _ -> :error
    end
  end

  defp ordinal({n, ""}, weekday) when n != 0 and n in -5..5, do: {:ok, {n, weekday}}
  defp ordinal(_, _), do: :error

  defp parse_monthdays(text) do
    text
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case Integer.parse(part) do
        {n, ""} when n != 0 and n in -31..31 -> {:cont, {:ok, [n | acc]}}
        _ -> {:halt, :error}
      end
    end)
  end

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
      # An instance whose wall clock does not exist (spring forward) is
      # ignored and not counted, RFC 5545 §3.3.10; DTSTART itself is kept.
      |> Stream.reject(&(&1 != start and in_gap?(&1)))

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
  defp length_days({:nominal, days, seconds}), do: days + div(seconds, 86_400) + 2

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
    case parse_time(value, %{}, {start_zone(start), %{}}) do
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

  # A monthly rule with BYDAY and/or BYMONTHDAY: the matching days of each
  # INTERVAL-th month (both = days matching both), in order.
  defp candidates(start, %{"FREQ" => "MONTHLY"} = rule, interval)
       when is_map_key(rule, "BYDAY") or is_map_key(rule, "BYMONTHDAY") do
    first_date = start_date(start)
    {:ok, bydays} = rule |> Map.get("BYDAY") |> split_parts(&parse_byday/1)
    {:ok, monthdays} = rule |> Map.get("BYMONTHDAY") |> monthdays_or_nil()

    Stream.iterate(0, &(&1 + 1))
    |> Stream.flat_map(fn n ->
      %Date{year: y, month: m} = shift_months(%{first_date | day: 1}, n * interval)

      y
      |> month_matches(m, bydays, monthdays)
      |> Enum.map(&with_date(start, &1))
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

  defp split_parts(nil, _parser), do: {:ok, nil}

  defp split_parts(text, parser) do
    text
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case parser.(part) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp monthdays_or_nil(nil), do: {:ok, nil}
  defp monthdays_or_nil(text), do: parse_monthdays(text)

  defp month_matches(year, month, bydays, monthdays) do
    last = Date.days_in_month(Date.new!(year, month, 1))
    all = Enum.map(1..last, &Date.new!(year, month, &1))

    by_day =
      if bydays, do: MapSet.new(Enum.flat_map(bydays, &byday_dates(all, &1))), else: nil

    by_monthday =
      if monthdays,
        do:
          monthdays
          |> Enum.map(fn n -> if n > 0, do: n, else: last + 1 + n end)
          |> Enum.filter(&(&1 in 1..last))
          |> MapSet.new(&Date.new!(year, month, &1)),
        else: nil

    all
    |> Enum.filter(fn date ->
      (is_nil(by_day) or MapSet.member?(by_day, date)) and
        (is_nil(by_monthday) or MapSet.member?(by_monthday, date))
    end)
  end

  defp byday_dates(month_days, {nil, weekday}),
    do: Enum.filter(month_days, &(Date.day_of_week(&1) == weekday))

  defp byday_dates(month_days, {n, weekday}) do
    matching = Enum.filter(month_days, &(Date.day_of_week(&1) == weekday))
    index = if n > 0, do: n - 1, else: length(matching) + n

    case index >= 0 and Enum.at(matching, index) do
      %Date{} = date -> [date]
      _ -> []
    end
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
  defp to_utc({:local, naive, {:custom, observances}}) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.add(-custom_offset(naive, observances), :second)
  end

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

  # An instant handed out of the parser names an IANA zone: one of the feed's
  # own VTIMEZONEs is resolved to UTC here.
  defp public_instant({:local, _naive, {:custom, _}} = time),
    do: {:local, time |> to_utc() |> DateTime.to_naive(), "Etc/UTC"}

  defp public_instant(time), do: time

  defp in_gap?({:local, naive, zone}) when is_binary(zone),
    do: match?({:gap, _, _}, DateTime.from_naive(naive, zone, Tz.TimeZoneDatabase))

  defp in_gap?(_candidate), do: false

  # ── The feed's own VTIMEZONEs ────────────────────────────────────────
  #
  # Understood: observances (STANDARD / DAYLIGHT) with TZOFFSETTO and, for a
  # zone with clock changes, a yearly RRULE of BYMONTH + one (ordinal)
  # BYDAY — every zone Outlook and Google write. Anything else leaves the
  # TZID unknown: read in the default zone, and the event counted in
  # `:unsupported`.

  defp vtimezones(props) do
    {zones, _current, _observance} =
      Enum.reduce(props, {%{}, nil, nil}, fn
        {"BEGIN", _, "VTIMEZONE"}, {zones, nil, nil} ->
          {zones, %{tzid: nil, observances: []}, nil}

        {"BEGIN", _, kind}, {zones, %{} = zone, nil} when kind in ["STANDARD", "DAYLIGHT"] ->
          {zones, zone, %{}}

        {"END", _, kind}, {zones, zone, %{} = obs} when kind in ["STANDARD", "DAYLIGHT"] ->
          {zones, %{zone | observances: [obs | zone.observances]}, nil}

        {"END", _, "VTIMEZONE"}, {zones, %{tzid: tzid} = zone, nil} when is_binary(tzid) ->
          {put_zone(zones, tzid, zone.observances), nil, nil}

        {"END", _, "VTIMEZONE"}, {zones, _zone, _obs} ->
          {zones, nil, nil}

        {"TZID", _, tzid}, {zones, %{} = zone, nil} ->
          {zones, %{zone | tzid: String.trim(tzid)}, nil}

        {name, _, value}, {zones, zone, %{} = obs}
        when name in ["DTSTART", "TZOFFSETFROM", "TZOFFSETTO", "RRULE"] ->
          {zones, zone, Map.put(obs, name, String.trim(value))}

        _prop, acc ->
          acc
      end)

    zones
  end

  defp put_zone(zones, tzid, observances) do
    case Enum.map(observances, &observance/1) do
      [] ->
        zones

      parsed ->
        if Enum.all?(parsed, &is_map/1), do: Map.put(zones, tzid, {:custom, parsed}), else: zones
    end
  end

  defp observance(obs) do
    with {:ok, to} <- parse_offset(obs["TZOFFSETTO"]),
         {:ok, from} <- parse_offset(obs["TZOFFSETFROM"] || obs["TZOFFSETTO"]),
         {:ok, dtstart} <- parse_naive(obs["DTSTART"] || "19700101T000000"),
         {:ok, rule} <- observance_rule(obs["RRULE"]) do
      %{to: to, from: from, dtstart: dtstart, rule: rule}
    else
      _ -> :unsupported
    end
  end

  defp observance_rule(nil), do: {:ok, nil}

  defp observance_rule(rrule) do
    rule = parse_rrule(rrule)

    with "YEARLY" <- rule["FREQ"],
         {month, ""} when month in 1..12 <- Integer.parse(rule["BYMONTH"] || ""),
         {:ok, {n, weekday}} when not is_nil(n) <- parse_byday(rule["BYDAY"] || ""),
         true <- Enum.all?(Map.keys(rule), &(&1 in ~w(FREQ BYMONTH BYDAY UNTIL INTERVAL))) do
      {:ok, %{month: month, nth: n, weekday: weekday}}
    else
      _ -> :error
    end
  end

  defp parse_offset(nil), do: :error

  defp parse_offset(text) do
    case Regex.run(~r/^([+-])(\d{2})(\d{2})(\d{2})?$/, String.trim(text)) do
      [_, sign, h, m | rest] ->
        seconds = String.to_integer(h) * 3600 + String.to_integer(m) * 60 + seconds(rest)
        {:ok, if(sign == "-", do: -seconds, else: seconds)}

      _ ->
        :error
    end
  end

  defp seconds([s]) when s != "", do: String.to_integer(s)
  defp seconds(_), do: 0

  # The offset in force at a wall clock: that of the observance with the
  # latest onset at or before it (this year's or last year's), or, before
  # any onset, the earliest observance's offset before it.
  defp custom_offset(naive, observances) do
    onsets =
      for obs <- observances,
          year <- [naive.year - 1, naive.year],
          onset = onset(obs, year),
          onset != nil,
          NaiveDateTime.compare(onset, naive) != :gt,
          do: {onset, obs.to}

    case Enum.max_by(onsets, fn {onset, _} -> NaiveDateTime.to_gregorian_seconds(onset) end, fn ->
           nil
         end) do
      {_onset, offset} ->
        offset

      nil ->
        observances
        |> Enum.min_by(&NaiveDateTime.to_gregorian_seconds(&1.dtstart))
        |> Map.fetch!(:from)
    end
  end

  # Without a rule an observance holds from its DTSTART on.
  defp onset(%{rule: nil, dtstart: dtstart}, year),
    do: if(dtstart.year <= year, do: dtstart)

  defp onset(%{rule: rule, dtstart: dtstart}, year) do
    if year < dtstart.year do
      nil
    else
      days =
        Enum.map(
          1..Date.days_in_month(Date.new!(year, rule.month, 1)),
          &Date.new!(year, rule.month, &1)
        )

      case byday_dates(days, {rule.nth, rule.weekday}) do
        [date] -> NaiveDateTime.new!(date, NaiveDateTime.to_time(dtstart))
        [] -> nil
      end
    end
  end
end
