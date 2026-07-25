defmodule PhoenixKitBookings.Web.Public.ManageLive do
  @moduledoc """
  Guest self-service page (`/bookings/manage/:token`): view a booking via
  its signed manage token and cancel it while it hasn't started yet. No
  account needed — the token (mailed/shown at booking time) is the
  credential.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKitBookings.{Bookings, Engine, Errors, Services}
  alias PhoenixKitBookings.Web.Format

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"token" => token}, uri, socket) do
    booking = Bookings.booking_from_token(token)
    service = booking && Services.get_service(booking.service_uuid)

    {:noreply,
     assign(socket,
       url_path: URI.parse(uri).path,
       page_title: gettext("Your booking"),
       booking: booking,
       service: service
     )}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    case Bookings.cancel_booking(socket.assigns.booking, reason: "guest self-service") do
      {:ok, booking} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Your booking is cancelled."))
         |> assign(booking: booking)}

      {:error, reason, _} ->
        {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  defp cancellable?(nil), do: false

  defp cancellable?(booking) do
    booking.status in ["pending", "confirmed"] and upcoming?(booking)
  end

  defp upcoming?(%{starts_at: %DateTime{} = starts_at}),
    do: DateTime.compare(starts_at, DateTime.utc_now()) == :gt

  defp upcoming?(%{starts_on: %Date{} = starts_on}),
    do: Date.compare(starts_on, Engine.today()) != :lt

  defp upcoming?(_), do: false

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
      <div class="max-w-xl mx-auto px-4 py-10">
        <div :if={is_nil(@booking)} class="alert alert-warning">
          {gettext("This link is invalid or has expired.")}
        </div>

        <div :if={@booking} class="card bg-base-100 shadow-lg">
          <div class="card-body gap-3">
            <h1 class="card-title">{gettext("Your booking")}</h1>
            <div class="text-sm flex flex-col gap-1">
              <div :if={@service} class="font-medium">{@service.name}</div>
              <div>{Format.format_range(@booking)}</div>
              <div>
                <span class={Format.status_badge(@booking.status)}>{@booking.status}</span>
              </div>
              <div class="text-base-content/60">{@booking.customer_name} · {@booking.customer_email}</div>
            </div>

            <div :if={cancellable?(@booking)} class="card-actions mt-2">
              <button
                class="btn btn-error btn-sm"
                phx-click="cancel"
                data-confirm={gettext("Cancel this booking? This cannot be undone.")}
              >
                {gettext("Cancel booking")}
              </button>
            </div>
            <p :if={@booking.status == "cancelled"} class="text-sm text-base-content/60">
              {gettext("This booking has been cancelled.")}
            </p>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
