defmodule PhoenixKitBookings.Web.Public.EventLive do
  @moduledoc """
  One public event (`/bookings/events/:uuid`): what, when, where, who runs
  it, the places left, and a sign-up form that books a seat
  (`Bookings.create_event_booking/3`). The service's signup policy applies
  (a `login_required` service asks a guest to log in); the public mail rate
  limit applies as on the booking page. Live: the places left follow other
  sign-ups.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitBookings.Gettext

  require Logger

  alias PhoenixKitBookings.{Bookings, Errors, Events, HostProfiles, Paths, RateLimit, Services}
  alias PhoenixKitBookings.Schemas.Booking
  alias PhoenixKitBookings.Web.Format
  alias PhoenixKitBookings.Web.Public.{BookingFlow, EventCard}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, peer_ip: BookingFlow.peer_ip(socket), subscribed: nil)}
  end

  @impl true
  def handle_params(%{"uuid" => uuid}, uri, socket) do
    socket = assign(socket, url_path: URI.parse(uri).path, booking: nil, error: nil)

    case Events.get_public_event(uuid) do
      nil ->
        {:noreply, assign(socket, event: nil, page_title: gettext("Not found"))}

      event ->
        user = current_user(socket)

        {:noreply,
         socket
         |> subscribe(event.service_uuid)
         |> assign(
           event: event,
           page_title: event.title,
           current_user: user,
           form: to_form(Booking.customer_changeset(%Booking{}, prefill(user)))
         )
         |> load()}
    end
  end

  defp subscribe(socket, service_uuid) do
    if connected?(socket) and socket.assigns.subscribed != service_uuid do
      case PhoenixKit.Config.pubsub_server() do
        nil ->
          socket

        pubsub ->
          if socket.assigns.subscribed,
            do:
              Phoenix.PubSub.unsubscribe(
                pubsub,
                Bookings.service_topic(socket.assigns.subscribed)
              )

          Phoenix.PubSub.subscribe(pubsub, Bookings.service_topic(service_uuid))
          assign(socket, subscribed: service_uuid)
      end
    else
      socket
    end
  end

  defp load(%{assigns: %{event: event}} = socket) do
    service = Services.get_service(event.service_uuid)
    host_uuid = Events.host_profile_uuid(event, service)

    assign(socket,
      service: service,
      host: host_uuid && HostProfiles.get_profile(host_uuid),
      seats_left: if(service, do: Events.seats_left(event, service), else: 0)
    )
  end

  defp current_user(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: _} = user} -> user
      _ -> nil
    end
  end

  defp prefill(nil), do: %{}

  defp prefill(user) do
    %{"customer_email" => user.email, "customer_name" => Map.get(user, :username)}
  end

  @impl true
  def handle_event("validate", %{"booking" => params}, socket) do
    changeset = Booking.customer_changeset(%Booking{}, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("sign_up", _params, %{assigns: %{event: nil}} = socket),
    do: {:noreply, socket}

  # One sign-up per page: a replayed submit must not book a second seat.
  def handle_event("sign_up", _params, %{assigns: %{booking: %Booking{}}} = socket),
    do: {:noreply, socket}

  def handle_event("sign_up", %{"booking" => params}, socket) do
    %{event: event, current_user: user} = socket.assigns

    with :ok <- RateLimit.check(params["customer_email"], socket.assigns[:peer_ip]),
         {:ok, booking} <-
           Bookings.create_event_booking(event, params,
             user_uuid: user && user.uuid,
             source: "public"
           ) do
      {:noreply, socket |> assign(booking: booking, error: nil) |> load()}
    else
      {:error, :rate_limited} ->
        {:noreply, assign(socket, error: Errors.message(:rate_limited))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, reason, _message} ->
        {:noreply, socket |> assign(error: Errors.message(reason)) |> load()}
    end
  end

  @impl true
  def handle_info({:bookings_changed, _uuid}, %{assigns: %{event: %{}}} = socket),
    do: {:noreply, load(socket)}

  def handle_info(message, socket) do
    Logger.debug("Public.EventLive ignored unhandled message: #{inspect(message)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      current_path={assigns[:url_path] || "/"}
    >
      <div class="max-w-2xl mx-auto px-4 py-10 flex flex-col gap-6">
        <div :if={is_nil(@event)} class="alert alert-warning">
          {gettext("This event does not exist or is no longer on the schedule.")}
        </div>

        <%= if @event do %>
          <div class="flex flex-col gap-2" id="event-details">
            <h1 class="text-3xl font-bold">{@event.title}</h1>
            <p class="text-base-content/70">
              {EventCard.day_label(Format.frame_date(@event.starts_at))} · {EventCard.time_range(@event)}
            </p>
            <p :if={@event.location} class="text-base-content/70">{@event.location}</p>
            <p :if={@host}>
              {gettext("With")}
              <.link navigate={Paths.public_host(@host.slug)} class="link link-primary">
                {@host.name}
              </.link>
            </p>
            <p :if={@event.description} class="whitespace-pre-line mt-2">{@event.description}</p>
            <p :if={EventCard.price_text(@event, @service)} class="font-medium">
              {EventCard.price_text(@event, @service)}
            </p>
          </div>

          <div :if={@error} class="alert alert-warning text-sm">{@error}</div>

          <div :if={@booking} class="alert alert-success" id="event-signed-up">
            <span :if={@booking.status == "confirmed"}>
              {gettext("You're signed up. A confirmation email is on its way.")}
            </span>
            <span :if={@booking.status == "pending"}>
              {gettext("Request received. You'll hear back once it's approved.")}
            </span>
            <a href={Paths.public_manage(Bookings.manage_token(@booking))} class="link">
              {gettext("Manage or cancel")}
            </a>
          </div>

          <%= cond do %>
            <% @booking -> %>
            <% @seats_left == 0 -> %>
              <div class="alert" id="event-full">{gettext("This event is fully booked.")}</div>
            <% @service && @service.signup_policy == "login_required" && is_nil(@current_user) -> %>
              <div class="alert">{Errors.message(:login_required)}</div>
            <% true -> %>
              <p class="text-sm text-base-content/70">
                {ngettext("%{count} place left", "%{count} places left", @seats_left)}
              </p>
              <.form
                for={@form}
                id="event-signup"
                phx-change="validate"
                phx-submit="sign_up"
                class="flex flex-col gap-3"
              >
                <PhoenixKitWeb.Components.Core.Input.input
                  field={@form[:customer_name]}
                  type="text"
                  label={gettext("Your name")}
                />
                <PhoenixKitWeb.Components.Core.Input.input
                  field={@form[:customer_email]}
                  type="email"
                  label={gettext("Email")}
                />
                <PhoenixKitWeb.Components.Core.Input.input
                  field={@form[:customer_phone]}
                  type="tel"
                  label={gettext("Phone (optional)")}
                />
                <div>
                  <button type="submit" class="btn btn-primary">{gettext("Sign up")}</button>
                </div>
              </.form>
          <% end %>

          <.link navigate={Paths.public_schedule()} class="link">{gettext("Full schedule")}</.link>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
