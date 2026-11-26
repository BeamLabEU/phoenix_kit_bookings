defmodule PhoenixKitBookings.ICalImport.ParserTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBookings.ICalImport.Parser

  @from ~U[2026-01-01 00:00:00Z]
  @until ~U[2026-12-31 00:00:00Z]

  defp cal(body) do
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\n" <> body <> "END:VCALENDAR\r\n"
  end

  defp parse(body, opts \\ []) do
    {:ok, result} =
      Parser.parse(cal(body), Keyword.merge([from: @from, until: @until, tz: "Etc/UTC"], opts))

    result
  end

  test "a UTC event, unfolded summary with escapes" do
    %{events: [event]} =
      parse("""
      BEGIN:VEVENT\r
      UID:abc@example.com\r
      DTSTART:20260310T090000Z\r
      DTEND:20260310T113000Z\r
      SUMMARY:Rented\\, crane 7\r
       with operator\r
      END:VEVENT\r
      """)

    assert event.uid == "abc@example.com"
    assert event.summary == "Rented, crane 7with operator"
    assert event.range == {:datetime, ~U[2026-03-10 09:00:00Z], ~U[2026-03-10 11:30:00Z]}
    assert event.recurrence_id == nil
  end

  test "TZID times resolve through daylight saving (Tallinn, winter and summer)" do
    %{events: [winter, summer]} =
      parse("""
      BEGIN:VEVENT
      UID:w
      DTSTART;TZID=Europe/Tallinn:20260115T100000
      DTEND;TZID=Europe/Tallinn:20260115T120000
      END:VEVENT
      BEGIN:VEVENT
      UID:s
      DTSTART;TZID="Europe/Tallinn":20260715T100000
      DURATION:PT2H
      END:VEVENT
      """)

    assert winter.range == {:datetime, ~U[2026-01-15 08:00:00Z], ~U[2026-01-15 10:00:00Z]}
    assert summer.range == {:datetime, ~U[2026-07-15 07:00:00Z], ~U[2026-07-15 09:00:00Z]}
  end

  test "floating times and unknown TZIDs read in the given zone" do
    %{events: [floating, outlook]} =
      parse(
        """
        BEGIN:VEVENT
        UID:f
        DTSTART:20260115T100000
        DTEND:20260115T110000
        END:VEVENT
        BEGIN:VEVENT
        UID:o
        DTSTART;TZID=FLE Standard Time:20260116T100000
        DTEND;TZID=FLE Standard Time:20260116T110000
        END:VEVENT
        """,
        tz: "Europe/Tallinn"
      )

    assert floating.range == {:datetime, ~U[2026-01-15 08:00:00Z], ~U[2026-01-15 09:00:00Z]}
    assert outlook.range == {:datetime, ~U[2026-01-16 08:00:00Z], ~U[2026-01-16 09:00:00Z]}
  end

  test "all-day events: DTEND exclusive, missing DTEND is one day" do
    %{events: [two_days, one_day]} =
      parse("""
      BEGIN:VEVENT
      UID:a
      DTSTART;VALUE=DATE:20260301
      DTEND;VALUE=DATE:20260303
      END:VEVENT
      BEGIN:VEVENT
      UID:b
      DTSTART;VALUE=DATE:20260310
      END:VEVENT
      """)

    assert two_days.range == {:date, ~D[2026-03-01], ~D[2026-03-03]}
    assert one_day.range == {:date, ~D[2026-03-10], ~D[2026-03-11]}
  end

  test "cancelled and transparent events are not busy; a nested VALARM is ignored" do
    %{events: [event]} =
      parse("""
      BEGIN:VEVENT
      UID:busy
      DTSTART:20260310T090000Z
      DTEND:20260310T100000Z
      BEGIN:VALARM
      TRIGGER:-PT15M
      DESCRIPTION:not an event
      END:VALARM
      END:VEVENT
      BEGIN:VEVENT
      UID:cancelled
      STATUS:CANCELLED
      DTSTART:20260311T090000Z
      DTEND:20260311T100000Z
      END:VEVENT
      BEGIN:VEVENT
      UID:free
      TRANSP:TRANSPARENT
      DTSTART:20260312T090000Z
      DTEND:20260312T100000Z
      END:VEVENT
      """)

    assert event.uid == "busy"
  end

  test "weekly RRULE with BYDAY, COUNT and EXDATE; a moved instance replaces its original" do
    %{events: events} =
      parse("""
      BEGIN:VEVENT
      UID:weekly
      DTSTART;TZID=Europe/Tallinn:20260302T180000
      DTEND;TZID=Europe/Tallinn:20260302T190000
      RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=5
      EXDATE;TZID=Europe/Tallinn:20260304T180000
      END:VEVENT
      BEGIN:VEVENT
      UID:weekly
      RECURRENCE-ID;TZID=Europe/Tallinn:20260309T180000
      DTSTART;TZID=Europe/Tallinn:20260309T200000
      DTEND;TZID=Europe/Tallinn:20260309T210000
      END:VEVENT
      """)

    starts = Enum.map(events, fn %{range: {:datetime, s, _}} -> s end)

    # Mon 2, (Wed 4 excluded), Mon 9 moved to 20:00, Wed 11, Mon 16 — COUNT 5
    # counts the excluded one too.
    assert starts == [
             ~U[2026-03-02 16:00:00Z],
             ~U[2026-03-09 18:00:00Z],
             ~U[2026-03-11 16:00:00Z],
             ~U[2026-03-16 16:00:00Z]
           ]

    assert Enum.all?(events, &(&1.recurrence_id != nil))
  end

  test "daily rule across the spring-forward keeps the wall clock" do
    %{events: events} =
      parse("""
      BEGIN:VEVENT
      UID:d
      DTSTART;TZID=Europe/Tallinn:20260328T100000
      DTEND;TZID=Europe/Tallinn:20260328T110000
      RRULE:FREQ=DAILY;UNTIL=20260330T235959Z
      END:VEVENT
      """)

    assert Enum.map(events, fn %{range: {:datetime, s, _}} -> s end) == [
             ~U[2026-03-28 08:00:00Z],
             ~U[2026-03-29 07:00:00Z],
             ~U[2026-03-30 07:00:00Z]
           ]
  end

  test "an open-ended rule from years ago still reaches the window" do
    %{events: events} =
      parse(
        """
        BEGIN:VEVENT
        UID:old
        DTSTART:20150105T090000Z
        DTEND:20150105T100000Z
        RRULE:FREQ=DAILY
        END:VEVENT
        """,
        from: ~U[2026-06-01 00:00:00Z],
        until: ~U[2026-06-04 00:00:00Z]
      )

    assert length(events) == 3
  end

  test "monthly on the 31st skips short months; yearly works" do
    %{events: monthly} =
      parse("""
      BEGIN:VEVENT
      UID:m
      DTSTART;VALUE=DATE:20260131
      RRULE:FREQ=MONTHLY;COUNT=4
      END:VEVENT
      """)

    # A month without a 31st has no occurrence, and it does not count.
    assert Enum.map(monthly, fn %{range: {:date, d, _}} -> d end) ==
             [~D[2026-01-31], ~D[2026-03-31], ~D[2026-05-31], ~D[2026-07-31]]

    %{events: yearly} =
      parse(
        """
        BEGIN:VEVENT
        UID:y
        DTSTART;VALUE=DATE:20240601
        RRULE:FREQ=YEARLY
        END:VEVENT
        """,
        from: ~U[2026-01-01 00:00:00Z],
        until: ~U[2027-12-31 00:00:00Z]
      )

    assert Enum.map(yearly, fn %{range: {:date, d, _}} -> d end) == [
             ~D[2026-06-01],
             ~D[2027-06-01]
           ]
  end

  test "an unsupported rule imports its first occurrence and is counted" do
    %{events: [event], unsupported: 1} =
      parse("""
      BEGIN:VEVENT
      UID:u
      DTSTART:20260302T090000Z
      DTEND:20260302T100000Z
      RRULE:FREQ=MONTHLY;BYDAY=1MO
      END:VEVENT
      """)

    assert event.range == {:datetime, ~U[2026-03-02 09:00:00Z], ~U[2026-03-02 10:00:00Z]}
  end

  test "events outside the window are dropped, and a non-calendar is an error" do
    assert %{events: []} =
             parse("""
             BEGIN:VEVENT
             UID:old
             DTSTART:20200101T090000Z
             DTEND:20200101T100000Z
             END:VEVENT
             """)

    assert {:error, :not_a_calendar} = Parser.parse("<html></html>", from: @from, until: @until)
  end

  test "an event without UID or start is skipped" do
    assert %{events: []} =
             parse("""
             BEGIN:VEVENT
             DTSTART:20260310T090000Z
             DTEND:20260310T100000Z
             END:VEVENT
             BEGIN:VEVENT
             UID:x
             END:VEVENT
             """)
  end
end
