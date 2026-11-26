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
      RRULE:FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=1
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

  describe "review fixes" do
    test "escapes decode in one pass" do
      %{events: [event]} =
        parse("""
        BEGIN:VEVENT
        UID:e
        DTSTART:20260310T090000Z
        DTEND:20260310T100000Z
        SUMMARY:C:\\\\new\; a\\, b\\nc
        END:VEVENT
        """)

      assert event.summary == "C:\\new; a, b\nc"
    end

    test "a cancelled or transparent override removes its instance instead of bringing it back" do
      %{events: events} =
        parse("""
        BEGIN:VEVENT
        UID:r
        DTSTART:20260101T100000Z
        DTEND:20260101T110000Z
        RRULE:FREQ=DAILY;COUNT=3
        END:VEVENT
        BEGIN:VEVENT
        UID:r
        RECURRENCE-ID:20260102T100000Z
        DTSTART:20260102T100000Z
        DTEND:20260102T110000Z
        STATUS:CANCELLED
        END:VEVENT
        BEGIN:VEVENT
        UID:r
        RECURRENCE-ID:20260103T100000Z
        DTSTART:20260103T100000Z
        DTEND:20260103T110000Z
        TRANSP:TRANSPARENT
        END:VEVENT
        """)

      assert Enum.map(events, fn %{range: {:datetime, s, _}} -> s end) == [
               ~U[2026-01-01 10:00:00Z]
             ]
    end

    test "WKST decides which weeks an INTERVAL=2 rule skips" do
      %{events: events} =
        parse("""
        BEGIN:VEVENT
        UID:w
        DTSTART:20260104T100000Z
        DURATION:PT1H
        RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=SU,MO;WKST=SU
        END:VEVENT
        """)

      assert Enum.map(events, fn %{range: {:datetime, s, _}} -> DateTime.to_date(s) end) == [
               ~D[2026-01-04],
               ~D[2026-01-05],
               ~D[2026-01-18],
               ~D[2026-01-19]
             ]
    end

    test "a start inside the spring-forward gap reads with the offset before it" do
      %{events: [%{range: {:datetime, s, e}}]} =
        parse("""
        BEGIN:VEVENT
        UID:g
        DTSTART;TZID=America/New_York:20260308T023000
        DURATION:PT1H
        END:VEVENT
        """)

      assert s == ~U[2026-03-08 07:30:00Z]
      assert e == ~U[2026-03-08 08:30:00Z]
    end

    test "a body without END:VCALENDAR is not a calendar (a cut-off feed must not empty the import)" do
      assert {:error, :not_a_calendar} =
               Parser.parse("BEGIN:VCALENDAR\r\n", from: @from, until: @until)

      assert {:error, :not_a_calendar} =
               Parser.parse(
                 "BEGIN:VCALENDAR\r\nX-NOTE:END:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\n",
                 from: @from,
                 until: @until
               )

      assert {:error, :not_a_calendar} =
               Parser.parse(
                 "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\nDTSTART:20260310T090000Z\r\n",
                 from: @from,
                 until: @until
               )
    end

    test "a BOM and a folded END line still make a calendar" do
      body =
        "\uFEFFBEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\nDTSTART:20260310T090000Z\r\n" <>
          "DTEND:20260310T100000Z\r\nEND:VEVENT\r\nEND:VCAL\r\n ENDAR\r\n"

      assert {:ok, %{events: [%{uid: "a"}]}} = Parser.parse(body, from: @from, until: @until)
    end

    test "lowercase component names are read" do
      assert {:ok, %{events: [_]}} =
               Parser.parse(
                 "begin:vcalendar\nbegin:vevent\nuid:a\ndtstart:20260310T090000Z\n" <>
                   "dtend:20260310T100000Z\nend:vevent\nend:vcalendar\n",
                 from: @from,
                 until: @until
               )
    end

    test "a feed expanding past the feed-wide cap is refused, not truncated" do
      body =
        Enum.map_join(1..11, "", fn n ->
          "BEGIN:VEVENT\r\nUID:many-#{n}\r\nDTSTART:20260101T#{String.pad_leading("#{n}", 2, "0")}0000Z\r\n" <>
            "DURATION:PT30M\r\nRRULE:FREQ=DAILY;COUNT=2000\r\nEND:VEVENT\r\n"
        end)

      assert {:error, :too_many_events} =
               Parser.parse(cal(body), from: @from, until: ~U[2032-01-01 00:00:00Z])
    end

    test "an absurd DURATION is cut to a century at once instead of stalling the date arithmetic" do
      task =
        Task.async(fn ->
          parse("""
          BEGIN:VEVENT
          UID:long
          DTSTART:20260310T090000Z
          DURATION:PT99999999999999999999S
          END:VEVENT
          BEGIN:VEVENT
          UID:ok
          DTSTART:20260311T090000Z
          DURATION:P1W
          END:VEVENT
          """)
        end)

      assert %{events: [long, %{uid: "ok"}]} = Task.await(task, 5_000)
      assert {:datetime, ~U[2026-03-10 09:00:00Z], ends} = long.range
      assert DateTime.diff(ends, ~U[2026-03-10 09:00:00Z]) == 100 * 366 * 86_400
    end
  end

  describe "monthly BYDAY / BYMONTHDAY, VTIMEZONE, DST gaps, nominal days" do
    defp starts(events), do: Enum.map(events, fn %{range: {:datetime, s, _}} -> s end)

    test "ordinal BYDAY: the second Tuesday and the last Friday of each month" do
      %{events: events, unsupported: 0} =
        parse("""
        BEGIN:VEVENT
        UID:m
        DTSTART:20260113T090000Z
        DURATION:PT1H
        RRULE:FREQ=MONTHLY;COUNT=4;BYDAY=2TU,-1FR
        END:VEVENT
        """)

      assert starts(events) == [
               ~U[2026-01-13 09:00:00Z],
               ~U[2026-01-30 09:00:00Z],
               ~U[2026-02-10 09:00:00Z],
               ~U[2026-02-27 09:00:00Z]
             ]
    end

    test "BYMONTHDAY with a negative day, and both parts together" do
      %{events: events} =
        parse("""
        BEGIN:VEVENT
        UID:d
        DTSTART:20260115T090000Z
        DURATION:PT1H
        RRULE:FREQ=MONTHLY;COUNT=4;BYMONTHDAY=15,-1
        END:VEVENT
        """)

      assert starts(events) == [
               ~U[2026-01-15 09:00:00Z],
               ~U[2026-01-31 09:00:00Z],
               ~U[2026-02-15 09:00:00Z],
               ~U[2026-02-28 09:00:00Z]
             ]

      # Friday the 13th: BYDAY and BYMONTHDAY intersect.
      %{events: events} =
        parse("""
        BEGIN:VEVENT
        UID:f13
        DTSTART:20260213T090000Z
        DURATION:PT1H
        RRULE:FREQ=MONTHLY;COUNT=2;BYDAY=FR;BYMONTHDAY=13
        END:VEVENT
        """)

      assert starts(events) == [~U[2026-02-13 09:00:00Z], ~U[2026-03-13 09:00:00Z]]
    end

    test "a VTIMEZONE with STANDARD/DAYLIGHT rules resolves both seasons" do
      %{events: events, unsupported: 0} =
        parse("""
        BEGIN:VTIMEZONE
        TZID:FLE Standard Time
        BEGIN:STANDARD
        DTSTART:16010101T040000
        TZOFFSETFROM:+0300
        TZOFFSETTO:+0200
        RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10
        END:STANDARD
        BEGIN:DAYLIGHT
        DTSTART:16010101T030000
        TZOFFSETFROM:+0200
        TZOFFSETTO:+0300
        RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3
        END:DAYLIGHT
        END:VTIMEZONE
        BEGIN:VEVENT
        UID:w
        DTSTART;TZID=FLE Standard Time:20260115T100000
        DTEND;TZID=FLE Standard Time:20260115T110000
        END:VEVENT
        BEGIN:VEVENT
        UID:s
        DTSTART;TZID=FLE Standard Time:20260715T100000
        DTEND;TZID=FLE Standard Time:20260715T110000
        END:VEVENT
        """)

      assert starts(events) == [~U[2026-01-15 08:00:00Z], ~U[2026-07-15 07:00:00Z]]
    end

    test "a fixed-offset VTIMEZONE; an unknown TZID falls back and is counted" do
      %{events: events, unsupported: 1} =
        parse("""
        BEGIN:VTIMEZONE
        TZID:Custom +0530
        BEGIN:STANDARD
        DTSTART:19700101T000000
        TZOFFSETFROM:+0530
        TZOFFSETTO:+0530
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        UID:fixed
        DTSTART;TZID=Custom +0530:20260310T100000
        DURATION:PT1H
        END:VEVENT
        BEGIN:VEVENT
        UID:unknown
        DTSTART;TZID=Nowhere Standard Time:20260311T100000
        DURATION:PT1H
        END:VEVENT
        """)

      assert starts(events) == [~U[2026-03-10 04:30:00Z], ~U[2026-03-11 10:00:00Z]]
    end

    test "a generated instance inside the spring-forward gap is skipped and not counted" do
      %{events: events} =
        parse("""
        BEGIN:VEVENT
        UID:g
        DTSTART;TZID=America/New_York:20260307T023000
        DURATION:PT30M
        RRULE:FREQ=DAILY;COUNT=3
        END:VEVENT
        """)

      # 8 March 02:30 does not exist in New York; COUNT=3 still yields three.
      assert Enum.map(starts(events), &DateTime.to_date/1) == [
               ~D[2026-03-07],
               ~D[2026-03-09],
               ~D[2026-03-10]
             ]
    end

    test "P1D across a clock change is a calendar day, not 24 hours" do
      %{events: [%{range: {:datetime, s, e}}]} =
        parse("""
        BEGIN:VEVENT
        UID:day
        DTSTART;TZID=America/New_York:20260307T120000
        DURATION:P1D
        END:VEVENT
        """)

      assert s == ~U[2026-03-07 17:00:00Z]
      assert e == ~U[2026-03-08 16:00:00Z]
    end
  end

  describe "round-4 review fixes" do
    test "a monthly rule no month satisfies ends instead of spinning" do
      task =
        Task.async(fn ->
          parse("""
          BEGIN:VEVENT
          UID:hang
          DTSTART:20260101T090000Z
          DURATION:PT1H
          RRULE:FREQ=MONTHLY;COUNT=1;BYDAY=5FR;BYMONTHDAY=1
          END:VEVENT
          BEGIN:VEVENT
          UID:hang2
          DTSTART:20260101T090000Z
          DURATION:PT1H
          RRULE:FREQ=MONTHLY;BYDAY=5FR;BYMONTHDAY=1
          END:VEVENT
          """)
        end)

      assert %{events: []} = Task.await(task, 10_000)
    end

    test "a VTIMEZONE observance with UNTIL is not guessed at: the TZID falls back, counted" do
      %{unsupported: 1} =
        parse("""
        BEGIN:VTIMEZONE
        TZID:Old
        BEGIN:STANDARD
        DTSTART:19701025T030000
        TZOFFSETFROM:+0300
        TZOFFSETTO:+0200
        RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU;UNTIL=19901028T010000Z
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        UID:o
        DTSTART;TZID=Old:20260310T100000
        DURATION:PT1H
        END:VEVENT
        """)
    end
  end
end
