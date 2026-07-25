defmodule PhoenixKitBookings.Paths do
  @moduledoc """
  Every path this module navigates to, in one place, all routed through
  `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling. Use
  `url/1`-based helpers for absolute links (emails).
  """

  alias PhoenixKit.Utils.Routes

  # ── Admin ────────────────────────────────────────────────────────────

  def admin_reservations, do: Routes.path("/admin/bookings/reservations")
  def admin_services, do: Routes.path("/admin/bookings/services")
  def admin_service_new, do: Routes.path("/admin/bookings/services/new")
  def admin_service_edit(uuid), do: Routes.path("/admin/bookings/services/#{uuid}/edit")

  # ── Public ───────────────────────────────────────────────────────────

  def public_index, do: Routes.path("/bookings")
  def public_book(slug), do: Routes.path("/book/#{slug}")
  def public_manage(token), do: Routes.path("/bookings/manage/#{token}")
  def public_manage_url(token), do: Routes.url("/bookings/manage/#{token}")
end
