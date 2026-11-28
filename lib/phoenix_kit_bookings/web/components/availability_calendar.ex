defmodule PhoenixKitBookings.Web.Components.AvailabilityCalendar do
  @moduledoc """
  A display-only month calendar of a service's availability: each day reads
  free / partly booked / booked / closed (`PhoenixKitBookings.AvailabilityView`).
  It books nothing and needs no JS.

  Use it anywhere a page renders HEEx:

      <AvailabilityCalendar.month
        id="crane-7"
        month={~D[2026-12-01]}
        statuses={AvailabilityView.day_statuses(service, from, until)}
      />

  With `nav_event` set, prev/next buttons send that event with
  `phx-value-month` = the ISO date of the month to show (the routed page and
  the widget handle it in `BookingFlow`).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitBookings.Gettext

  attr(:id, :string, required: true)
  attr(:month, Date, required: true, doc: "any date in the month to show")

  attr(:statuses, :map,
    required: true,
    doc: "%{Date => :free | :partial | :booked | :closed | :past}"
  )

  attr(:nav_event, :string, default: nil)
  attr(:min_month, Date, default: nil, doc: "no prev button at or before this month")
  attr(:class, :string, default: nil)

  def month(assigns) do
    first = Date.beginning_of_month(assigns.month)

    assigns =
      assign(assigns,
        first: first,
        weeks: weeks(first),
        prev_month: first |> Date.add(-1) |> Date.beginning_of_month(),
        next_month: first |> Date.end_of_month() |> Date.add(1),
        show_prev:
          is_nil(assigns.min_month) or
            Date.compare(first, Date.beginning_of_month(assigns.min_month)) == :gt
      )

    ~H"""
    <div id={@id} class={["flex flex-col gap-3", @class]} data-availability-calendar>
      <div class="flex items-center justify-between gap-2">
        <button
          :if={@nav_event && @show_prev}
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click={@nav_event}
          phx-value-month={Date.to_iso8601(@prev_month)}
          aria-label={gettext("Previous month")}
        >
          ‹
        </button>
        <span :if={!(@nav_event && @show_prev)} class="w-8"></span>
        <h4 class="font-semibold">{month_label(@first)}</h4>
        <button
          :if={@nav_event}
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click={@nav_event}
          phx-value-month={Date.to_iso8601(@next_month)}
          aria-label={gettext("Next month")}
        >
          ›
        </button>
        <span :if={!@nav_event} class="w-8"></span>
      </div>

      <div class="grid grid-cols-7 gap-1 text-center text-xs">
        <div :for={label <- weekday_labels()} class="font-medium text-base-content/60 py-1">
          {label}
        </div>
        <%= for week <- @weeks, day <- week do %>
          <div
            :if={day}
            class={["rounded py-2", status_class(Map.get(@statuses, day))]}
            title={status_label(Map.get(@statuses, day))}
            data-date={Date.to_iso8601(day)}
            data-status={Map.get(@statuses, day)}
          >
            {day.day}
          </div>
          <div :if={!day}></div>
        <% end %>
      </div>

      <div class="flex flex-wrap gap-3 text-xs text-base-content/70">
        <span :for={status <- [:free, :partial, :booked, :closed]} class="flex items-center gap-1">
          <span class={["inline-block w-3 h-3 rounded", status_class(status)]}></span>
          {status_label(status)}
        </span>
      </div>
    </div>
    """
  end

  # Weeks Monday-first, nil-padded at both ends.
  defp weeks(first) do
    last = Date.end_of_month(first)
    lead = List.duplicate(nil, Date.day_of_week(first) - 1)
    days = Enum.to_list(Date.range(first, last))
    trail = List.duplicate(nil, rem(7 - rem(length(lead) + length(days), 7), 7))

    (lead ++ days ++ trail) |> Enum.chunk_every(7)
  end

  @doc "CSS classes of a day cell."
  def status_class(:free), do: "bg-success/20 text-success-content"
  def status_class(:partial), do: "bg-warning/30"
  def status_class(:booked), do: "bg-error/30"
  def status_class(:closed), do: "bg-base-200 text-base-content/40"
  def status_class(:past), do: "text-base-content/30"
  def status_class(_), do: ""

  @doc "Human label of a day status."
  def status_label(:free), do: gettext("Free")
  def status_label(:partial), do: gettext("Partly booked")
  def status_label(:booked), do: gettext("Booked")
  def status_label(:closed), do: gettext("Closed")
  def status_label(:past), do: gettext("Past")
  def status_label(_), do: ""

  defp weekday_labels do
    [
      gettext("Mon"),
      gettext("Tue"),
      gettext("Wed"),
      gettext("Thu"),
      gettext("Fri"),
      gettext("Sat"),
      gettext("Sun")
    ]
  end

  @doc "\"December 2026\", the month name translated."
  def month_label(%Date{month: month, year: year}) do
    "#{month_name(month)} #{year}"
  end

  defp month_name(1), do: gettext("January")
  defp month_name(2), do: gettext("February")
  defp month_name(3), do: gettext("March")
  defp month_name(4), do: gettext("April")
  defp month_name(5), do: gettext("May")
  defp month_name(6), do: gettext("June")
  defp month_name(7), do: gettext("July")
  defp month_name(8), do: gettext("August")
  defp month_name(9), do: gettext("September")
  defp month_name(10), do: gettext("October")
  defp month_name(11), do: gettext("November")
  defp month_name(12), do: gettext("December")
end
