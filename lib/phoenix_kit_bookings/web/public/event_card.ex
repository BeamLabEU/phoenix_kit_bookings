defmodule PhoenixKitBookings.Web.Public.EventCard do
  @moduledoc """
  The event card the public schedule and host pages share, plus the batch
  lookups that feed it (`card_assigns/1`: services, host profiles and seats
  left for a list of events, in batched queries).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitBookings.Gettext

  alias PhoenixKitBookings.{Bookings, Engine, Events, HostProfiles, Paths, Pricing, Services}
  alias PhoenixKitBookings.Schemas.{Event, Service}
  alias PhoenixKitBookings.Web.Components.AvailabilityCalendar

  @doc "Assigns for a list of events: `services`, `hosts_by_uuid`, `seats_left`."
  def card_assigns(events) do
    services =
      events
      |> Enum.map(& &1.service_uuid)
      |> Enum.uniq()
      |> Services.list_active_by_uuid()
      |> Services.with_effective_seats()
      |> Map.new(&{&1.uuid, &1})

    hosts =
      events
      |> Enum.map(&host_uuid(&1, services))
      |> HostProfiles.public_profiles_by_uuid()

    taken = Bookings.event_seats_taken_map(Enum.map(events, & &1.uuid))

    seats_left =
      Map.new(events, fn event ->
        capacity =
          case services[event.service_uuid] do
            %Service{} = service -> event.capacity || service.seats
            nil -> event.capacity || 0
          end

        {event.uuid, max(capacity - Map.get(taken, event.uuid, 0), 0)}
      end)

    [services: services, hosts_by_uuid: hosts, seats_left: seats_left]
  end

  @doc "The host profile uuid an event shows (its own, else its service's)."
  def host_uuid(%Event{} = event, services),
    do: Events.host_profile_uuid(event, services[event.service_uuid])

  attr(:event, Event, required: true)
  attr(:service, :any, default: nil)
  attr(:host, :any, default: nil)
  attr(:seats_left, :integer, default: nil)

  def card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow" id={"event-#{@event.uuid}"}>
      <div class="card-body gap-2">
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <h3 class="card-title text-base">{@event.title}</h3>
          <span class="text-sm text-base-content/70">{time_range(@event)}</span>
        </div>
        <p :if={@event.location} class="text-sm text-base-content/60">{@event.location}</p>
        <p :if={@host} class="text-sm">
          {gettext("With")}
          <.link navigate={Paths.public_host(@host.slug)} class="link link-primary">{@host.name}</.link>
        </p>
        <div class="flex flex-wrap items-center justify-between gap-2">
          <span class="text-sm">
            <span :if={@seats_left == 0} class="badge badge-error">{gettext("Full")}</span>
            <span :if={@seats_left && @seats_left > 0} class="text-base-content/70">
              {ngettext("%{count} place left", "%{count} places left", @seats_left)}
            </span>
            <span :if={price_text(@event, @service)} class="ml-2 font-medium">
              {price_text(@event, @service)}
            </span>
          </span>
          <.link
            :if={@seats_left && @seats_left > 0}
            navigate={Paths.public_event(@event.uuid)}
            class="btn btn-primary btn-sm"
          >
            {gettext("Sign up")}
          </.link>
        </div>
      </div>
    </div>
    """
  end

  @doc "\"18:00–19:30\" in the site frame (dates added when it spans days)."
  def time_range(%Event{starts_at: starts_at, ends_at: ends_at}) do
    tz = Engine.site_tz()
    s = Engine.to_frame(starts_at, tz)
    e = Engine.to_frame(ends_at, tz)

    if DateTime.to_date(s) == DateTime.to_date(e) do
      "#{Calendar.strftime(s, "%H:%M")}–#{Calendar.strftime(e, "%H:%M")}"
    else
      "#{Calendar.strftime(s, "%d.%m %H:%M")} – #{Calendar.strftime(e, "%d.%m %H:%M")}"
    end
  end

  @doc "\"Tuesday, 1 December 2026\"-style heading of a schedule day."
  def day_label(%Date{} = date) do
    "#{weekday_name(Date.day_of_week(date))}, #{date.day} #{AvailabilityCalendar.month_label(date)}"
  end

  defp weekday_name(1), do: gettext("Monday")
  defp weekday_name(2), do: gettext("Tuesday")
  defp weekday_name(3), do: gettext("Wednesday")
  defp weekday_name(4), do: gettext("Thursday")
  defp weekday_name(5), do: gettext("Friday")
  defp weekday_name(6), do: gettext("Saturday")
  defp weekday_name(7), do: gettext("Sunday")

  @doc "The event's price for display, nil when free/unpriced."
  def price_text(%Event{price: %Decimal{} = price}, %Service{currency: currency}),
    do: Pricing.format(Decimal.round(price, 2), currency)

  def price_text(%Event{price: nil} = event, %Service{} = service),
    do: Pricing.format(Pricing.total(service, {event.starts_at, event.ends_at}), service.currency)

  def price_text(_event, _service), do: nil
end
