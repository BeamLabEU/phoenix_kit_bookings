defmodule PhoenixKitBookings.Web.Admin.ServiceFormLive do
  @moduledoc """
  Create/edit form for a bookable service. The form is mode-aware: picking
  a `time_unit` (and, for minute services, toggling free-form) swaps the
  relevant rule fields in and out. Availability rules are managed inline
  on the edit page (a service must exist before rules can reference it).
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitBookings.Gettext

  alias PhoenixKit.Users.Auth
  alias PhoenixKitBookings.{HostProfiles, ICalImport, Paths, Policy, PriceOptions, Pricing}
  alias PhoenixKitBookings.{RegularSlots, Services}
  alias PhoenixKitBookings.Schemas.{PriceOption, Service}
  alias PhoenixKitBookings.Web.Format

  @impl true
  def mount(params, _session, socket) do
    {service, action} =
      case params["uuid"] do
        nil -> {%Service{}, :new}
        uuid -> {Services.get_service(uuid) || %Service{}, :edit}
      end

    scope = socket.assigns[:phoenix_kit_current_scope]

    blocked? =
      case action do
        :new -> not Policy.can_create?(scope)
        :edit -> is_nil(service.uuid) or not Policy.can_manage?(scope, service)
      end

    if blocked? do
      {:ok,
       socket
       |> put_flash(:error, gettext("You can't edit that service."))
       |> push_navigate(to: Paths.admin_services())}
    else
      {:ok,
       socket
       |> assign(header_assigns(action, service))
       |> assign(
         action: action,
         service: service,
         providers: provider_options(),
         host_profiles: host_profile_options(),
         syncing: false,
         form: to_form(Service.changeset(service, %{}))
       )
       |> load_rules()}
    end
  end

  # Header trail: Bookings / Services / New service, and
  # Bookings / Services / <service> / Edit. The service has no page of its
  # own (the list is it), so its crumb is text, not a link. `heading` is
  # the in-page title, which names the record where the trail says "Edit".
  defp header_assigns(:new, _service) do
    [
      page_section: gettext("Bookings"),
      page_section_path: Paths.admin_reservations(),
      page_crumbs: [%{label: gettext("Services"), path: Paths.admin_services()}],
      page_title: gettext("New service"),
      heading: gettext("New service")
    ]
  end

  defp header_assigns(:edit, service) do
    [
      page_section: gettext("Bookings"),
      page_section_path: Paths.admin_reservations(),
      page_crumbs: [
        %{label: gettext("Services"), path: Paths.admin_services()},
        %{label: service.name}
      ],
      page_title: gettext("Edit"),
      heading: service.name
    ]
  end

  defp load_rules(%{assigns: %{service: %Service{uuid: nil}}} = socket),
    do: assign(socket, rules: [], units: [], price_options: [], regular_slots: [])

  defp load_rules(%{assigns: %{service: service}} = socket) do
    socket
    |> assign(
      rules: Services.list_rules(service.uuid),
      price_options: PriceOptions.list_options(service.uuid),
      regular_slots: RegularSlots.list_slots(service.uuid)
    )
    |> load_units()
  end

  defp host_profile_options do
    Enum.map(HostProfiles.list_profiles(), &{&1.name, &1.uuid})
  rescue
    _ -> []
  end

  defp load_units(%{assigns: %{service: %Service{uuid: nil}}} = socket),
    do: assign(socket, units: [])

  defp load_units(%{assigns: %{service: service}} = socket),
    do: assign(socket, units: Services.list_units(service.uuid))

  # Staff is an optional module — read its people SCHEMALESSLY from the
  # sibling table when it exists (the `phoenix_kit_calendar` cross-module
  # pattern: no compile-time reference, graceful absence). Read once at mount:
  # the form renders on every keystroke. A person's own `name` is usually blank,
  # so the label falls back through their account, as staff's own pages do.
  defp provider_options do
    repo = PhoenixKit.RepoHelper.repo()

    case repo.query("SELECT to_regclass('phoenix_kit_staff_people')", []) do
      {:ok, %{rows: [[nil]]}} ->
        []

      {:ok, _} ->
        import Ecto.Query, only: [from: 2]

        from(p in "phoenix_kit_staff_people",
          left_join: u in "phoenix_kit_users",
          on: u.uuid == p.user_uuid,
          where: p.status == "active",
          select: {p.name, u.first_name, u.last_name, u.email, type(p.uuid, :string)}
        )
        |> repo.all()
        |> Enum.map(fn {name, first_name, last_name, email, uuid} ->
          {provider_label(name, first_name, last_name, email, uuid), uuid}
        end)
        |> Enum.sort_by(fn {label, _uuid} -> String.downcase(label) end)

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp provider_label(name, first_name, last_name, email, uuid) do
    full_name =
      [first_name, last_name]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    Enum.find([name, full_name, email], &(&1 not in [nil, ""])) ||
      gettext("Person %{id}", id: String.slice(uuid, 0, 8))
  end

  @impl true
  def handle_event("validate", %{"service" => params}, socket) do
    changeset = Service.changeset(socket.assigns.service, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"service" => params}, socket) do
    save(socket, socket.assigns.action, params)
  end

  def handle_event("add_rule", %{"rule" => params}, socket) do
    attrs = normalize_rule_params(params)

    case Policy.add_rule(scope(socket), socket.assigns.service, attrs) do
      {:ok, _rule} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Availability rule added.")) |> load_rules()}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("You can't edit that service."))}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, rule_error(changeset))}
    end
  end

  def handle_event("add_unit", %{"unit" => params}, socket) do
    case Policy.add_unit(scope(socket), socket.assigns.service, params) do
      {:ok, _unit} ->
        {:noreply, socket |> put_flash(:info, gettext("Unit added.")) |> load_units()}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("You can't edit that service."))}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, rule_error(changeset))}
    end
  end

  def handle_event("toggle_unit", %{"uuid" => uuid}, socket) do
    with %{} = unit <- Enum.find(socket.assigns.units, &(&1.uuid == uuid)),
         {:ok, _} <-
           Policy.set_unit_active(scope(socket), socket.assigns.service, unit, !unit.active) do
      {:noreply, socket |> put_flash(:info, gettext("Unit updated.")) |> load_units()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not update that unit."))}
    end
  end

  def handle_event("delete_unit", %{"uuid" => uuid}, socket) do
    with %{} = unit <- Enum.find(socket.assigns.units, &(&1.uuid == uuid)),
         {:ok, _} <- Policy.delete_unit(scope(socket), socket.assigns.service, unit) do
      {:noreply, socket |> put_flash(:info, gettext("Unit deleted.")) |> load_units()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not delete that unit."))}
    end
  end

  def handle_event("add_price_option", %{"price_option" => params}, socket) do
    attrs = normalize_option_params(params)

    case Policy.add_price_option(scope(socket), socket.assigns.service, attrs) do
      {:ok, _option} ->
        {:noreply, socket |> put_flash(:info, gettext("Price option added.")) |> load_rules()}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("You can't edit that service."))}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, rule_error(changeset))}
    end
  end

  def handle_event("toggle_price_option", %{"uuid" => uuid}, socket) do
    with %PriceOption{} = option <- Enum.find(socket.assigns.price_options, &(&1.uuid == uuid)),
         {:ok, _} <-
           Policy.update_price_option(scope(socket), socket.assigns.service, option, %{
             "active" => !option.active
           }) do
      {:noreply, socket |> put_flash(:info, gettext("Price option updated.")) |> load_rules()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not update that price option."))}
    end
  end

  def handle_event("delete_price_option", %{"uuid" => uuid}, socket) do
    with %PriceOption{} = option <- Enum.find(socket.assigns.price_options, &(&1.uuid == uuid)),
         {:ok, _} <- Policy.delete_price_option(scope(socket), socket.assigns.service, option) do
      {:noreply, socket |> put_flash(:info, gettext("Price option deleted.")) |> load_rules()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not delete that price option."))}
    end
  end

  def handle_event("add_regular_slot", %{"regular_slot" => params}, socket) do
    attrs = %{
      "day_of_week" => params["day_of_week"],
      "start_time" => presence(params["start_time"]),
      "end_time" => presence(params["end_time"]),
      "customer_name" => presence(params["customer_name"]),
      "customer_email" => presence(params["customer_email"]),
      "user_uuid" => resolve_user_uuid(params["customer_email"]),
      "notes" => presence(params["notes"])
    }

    case Policy.add_regular_slot(scope(socket), socket.assigns.service, attrs) do
      {:ok, _slot} ->
        {:noreply, socket |> put_flash(:info, gettext("Regular slot added.")) |> load_rules()}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("You can't edit that service."))}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, rule_error(changeset))}
    end
  end

  def handle_event("delete_regular_slot", %{"uuid" => uuid}, socket) do
    with %{} = slot <- Enum.find(socket.assigns.regular_slots, &(&1.uuid == uuid)),
         {:ok, _} <- Policy.delete_regular_slot(scope(socket), socket.assigns.service, slot) do
      {:noreply, socket |> put_flash(:info, gettext("Regular slot removed.")) |> load_rules()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not remove that regular slot."))}
    end
  end

  # The feed is fetched off the LiveView process: a slow calendar server must
  # not freeze the form.
  def handle_event("sync_ical", _params, %{assigns: %{syncing: true}} = socket),
    do: {:noreply, socket}

  def handle_event("sync_ical", _params, socket) do
    scope = scope(socket)
    service = socket.assigns.service

    if Policy.can_manage?(scope, service) do
      {:noreply,
       socket
       |> assign(syncing: true)
       |> start_async(:sync_ical, fn -> Policy.sync_ical(scope, service) end)}
    else
      {:noreply, put_flash(socket, :error, gettext("You can't edit that service."))}
    end
  end

  def handle_event("delete_rule", %{"uuid" => uuid}, socket) do
    with %{} = rule <- Enum.find(socket.assigns.rules, &(&1.uuid == uuid)),
         {:ok, _} <- Policy.delete_rule(scope(socket), socket.assigns.service, rule) do
      {:noreply,
       socket |> put_flash(:info, gettext("Availability rule removed.")) |> load_rules()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not remove that rule."))}
    end
  end

  @impl true
  def handle_async(:sync_ical, result, socket) do
    socket =
      socket
      |> assign(syncing: false)
      |> assign(
        service: Services.get_service(socket.assigns.service.uuid) || socket.assigns.service
      )
      |> load_rules()

    case result do
      {:ok, {:ok, stats}} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Calendar synced: %{inserted} added, %{updated} updated, %{deleted} removed.",
             inserted: stats.inserted,
             updated: stats.updated,
             deleted: stats.deleted
           )
         )}

      {:ok, {:error, :not_allowed}} ->
        {:noreply, put_flash(socket, :error, gettext("You can't edit that service."))}

      {:ok, {:error, reason}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Calendar sync failed: %{reason}", reason: ICalImport.describe(reason))
         )}

      {:exit, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Calendar sync failed: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # A "users" option lists accounts by email, one per line or comma.
  defp normalize_option_params(params) do
    %{
      "name" => params["name"],
      "description" => presence(params["description"]),
      "price" => params["price"],
      "price_per" => presence(params["price_per"]),
      "entitlement" => params["entitlement"] || "everyone",
      "role_name" => presence(params["role_name"]),
      "flag_key" => presence(params["flag_key"]),
      "user_uuids" => resolve_user_uuids(params["user_emails"])
    }
  end

  defp resolve_user_uuids(nil), do: []

  defp resolve_user_uuids(text) do
    text
    |> String.split([",", "\n", " "], trim: true)
    |> Enum.map(&resolve_user_uuid/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp resolve_user_uuid(email) when is_binary(email) and email != "" do
    case Auth.get_user_by_email(String.trim(email)) do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp resolve_user_uuid(_), do: nil

  defp entitlement_label(%PriceOption{entitlement: "everyone"}), do: gettext("Everyone")

  defp entitlement_label(%PriceOption{entitlement: "users", user_uuids: uuids}),
    do: ngettext("%{count} chosen account", "%{count} chosen accounts", length(uuids || []))

  defp entitlement_label(%PriceOption{entitlement: "role", role_name: role}),
    do: gettext("Role: %{role}", role: role)

  defp entitlement_label(%PriceOption{entitlement: "flag", flag_key: key}),
    do: gettext("Members with flag: %{flag}", flag: key)

  defp entitlement_label(_), do: ""

  defp slot_holder(slot) do
    Enum.find([slot.customer_name, slot.customer_email], &(&1 not in [nil, ""])) || "—"
  end

  defp slot_hours(%{start_time: %Time{} = s, end_time: %Time{} = e}),
    do: "#{Calendar.strftime(s, "%H:%M")}–#{Calendar.strftime(e, "%H:%M")}"

  defp slot_hours(_), do: gettext("whole day")

  defp weekday_label(num), do: Enum.find_value(weekdays(), fn {n, label} -> n == num && label end)

  defp save(socket, :new, params) do
    case Policy.create_service(scope(socket), params) do
      {:ok, service} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{name} created. Now add availability rules if needed.", name: service.name)
         )
         |> push_navigate(to: Paths.admin_service_edit(service.uuid))}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("You can't create more services."))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :insert))}
    end
  end

  defp save(socket, :edit, params) do
    case Policy.update_service(scope(socket), socket.assigns.service, params) do
      {:ok, service} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} saved.", name: service.name))
         |> assign(service: service, form: to_form(Service.changeset(service, %{})))}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("You can't edit that service."))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :update))}
    end
  end

  defp scope(socket), do: socket.assigns[:phoenix_kit_current_scope]

  # The add-rule mini-form posts raw params; normalize the checkbox array
  # and drop blanks so the changeset sees clean input.
  defp normalize_rule_params(params) do
    days =
      params
      |> Map.get("days_of_week", [])
      |> Enum.map(&String.to_integer/1)

    %{
      "days_of_week" => if(days == [], do: nil, else: days),
      "date" => presence(params["date"]),
      "start_time" => presence(params["start_time"]),
      "end_time" => presence(params["end_time"]),
      "available" => params["available"] != "false"
    }
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp rule_error(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)
  end

  defp weekdays do
    [
      {1, gettext("Mon")},
      {2, gettext("Tue")},
      {3, gettext("Wed")},
      {4, gettext("Thu")},
      {5, gettext("Fri")},
      {6, gettext("Sat")},
      {7, gettext("Sun")}
    ]
  end

  defp time_unit_value(form), do: form[:time_unit].value || "minutes"
  defp flexible?(form), do: form[:flexible_duration].value in [true, "true"]
  defp minutes?(form), do: time_unit_value(form) == "minutes"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-8 gap-6 max-w-3xl">
      <div class="flex items-center justify-between">
        <h2 class="text-2xl font-bold">{@heading}</h2>
        <.link navigate={Paths.admin_services()} class="btn btn-ghost btn-sm">
          {gettext("Back to services")}
        </.link>
      </div>

      <.form
        for={@form}
        id="bookings-service-form"
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col gap-6"
      >
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body gap-4">
            <h3 class="card-title text-base">{gettext("Basics")}</h3>
            <.input field={@form[:name]} type="text" label={gettext("Name")} />
            <.input
              field={@form[:slug]}
              type="text"
              label={gettext("Slug (public URL: /book/<slug>)")}
              placeholder={gettext("auto-generated from the name when left blank")}
            />
            <.textarea field={@form[:description]} label={gettext("Description")} />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <.input
                field={@form[:host_ref]}
                type="text"
                label={gettext("Host reference (optional)")}
                placeholder={gettext("e.g. machine:42 — links this service to a record of your site")}
              />
              <.select
                :if={@host_profiles != []}
                field={@form[:host_profile_uuid]}
                label={gettext("Run by (public host profile)")}
                prompt={gettext("No host profile")}
                options={@host_profiles}
              />
            </div>
            <.checkbox
              field={@form[:bookable_online]}
              label={gettext("Bookable on the site (off: the public page only shows availability)")}
            />
          </div>
        </div>

        <div class="card bg-base-100 shadow-lg">
          <div class="card-body gap-4">
            <h3 class="card-title text-base">{gettext("Booking shape")}</h3>

            <.select
              field={@form[:time_unit]}
              label={gettext("Time unit")}
              options={[
                {gettext("Minutes — timed bookings (slots or free-form)"), "minutes"},
                {gettext("Nights — hotel-style stays (checkout day not charged)"), "night"},
                {gettext("Days — full-day bookings"), "day"}
              ]}
            />

            <div :if={minutes?(@form)} class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <.input
                field={@form[:duration]}
                type="number"
                label={gettext("Default length (minutes)")}
              />
              <.input
                field={@form[:slot_interval]}
                type="number"
                label={gettext("Slot start every (minutes, blank = length)")}
              />
              <div class="sm:col-span-2">
                <.checkbox
                  field={@form[:flexible_duration]}
                  label={gettext("Free-form: customers pick their own start and length")}
                />
              </div>
              <%= if flexible?(@form) do %>
                <.input
                  field={@form[:min_duration]}
                  type="number"
                  label={gettext("Minimum length (minutes, blank = default length)")}
                />
                <.input
                  field={@form[:max_duration]}
                  type="number"
                  label={gettext("Maximum length (minutes, blank = unlimited)")}
                />
              <% end %>
              <.input
                field={@form[:buffer_before]}
                type="number"
                label={gettext("Buffer before (minutes)")}
              />
              <.input
                field={@form[:buffer_after]}
                type="number"
                label={gettext("Buffer after (minutes)")}
              />
            </div>

            <div :if={!minutes?(@form)} class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <.input field={@form[:min_stay]} type="number" label={gettext("Minimum stay (blank = 1)")} />
              <.input
                field={@form[:max_stay]}
                type="number"
                label={gettext("Maximum stay (blank = unlimited)")}
              />
              <.input field={@form[:checkin_time]} type="time" label={gettext("Check-in time")} />
              <.input field={@form[:checkout_time]} type="time" label={gettext("Check-out time")} />
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
              <.input
                field={@form[:seats]}
                type="number"
                label={gettext("Capacity (rooms / seats per slot)")}
              />
              <.input
                field={@form[:min_notice]}
                type="number"
                label={gettext("Minimum notice (minutes)")}
              />
              <.input
                field={@form[:max_advance]}
                type="number"
                label={gettext("Book at most (days ahead, blank = no limit)")}
              />
            </div>
          </div>
        </div>

        <div class="card bg-base-100 shadow-lg">
          <div class="card-body gap-4">
            <h3 class="card-title text-base">{gettext("Signup policy")}</h3>
            <.select
              field={@form[:signup_policy]}
              label={gettext("Who can book")}
              options={[
                {gettext("Anyone — guests book with name and email"), "anyone"},
                {gettext("Login required"), "login_required"}
              ]}
            />
            <.checkbox
              field={@form[:require_approval]}
              label={gettext("Require approval — new bookings wait as pending (RSVP)")}
            />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <.input
                field={@form[:cancel_notice]}
                type="number"
                label={gettext("Customers may cancel until (minutes before start, 0 = anytime)")}
              />
              <.input
                field={@form[:reminder_minutes]}
                type="number"
                label={gettext("Reminder email (minutes before start, blank = none)")}
              />
            </div>
            <.select
              :if={@providers != []}
              field={@form[:provider_uuid]}
              label={gettext("Provider (staff person — their bookings block each other across services)")}
              prompt={gettext("No provider")}
              options={@providers}
            />
          </div>
        </div>

        <div class="card bg-base-100 shadow-lg">
          <div class="card-body gap-4">
            <h3 class="card-title text-base">{gettext("Pricing")}</h3>
            <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
              <.input
                field={@form[:price]}
                type="number"
                step="0.01"
                label={gettext("Price (blank = unpriced)")}
              />
              <.select
                field={@form[:price_per]}
                label={gettext("Per")}
                options={[
                  {gettext("Booking (flat)"), "booking"},
                  {gettext("Hour"), "hour"},
                  {gettext("Day"), "day"},
                  {gettext("Night"), "night"}
                ]}
              />
              <.input field={@form[:currency]} type="text" label={gettext("Currency")} />
            </div>
            <p class="text-xs text-base-content/50">
              {gettext("Totals are computed and stored on each booking. Payment collection is not wired yet — bookings record what is owed.")}
            </p>
          </div>
        </div>

        <div class="card bg-base-100 shadow-lg" id="bookings-ical-card">
          <div class="card-body gap-4">
            <h3 class="card-title text-base">{gettext("External calendar (iCal import)")}</h3>
            <p class="text-sm text-base-content/60">
              {gettext("Busy times from another calendar (an .ics / webcal link) are imported as bookings marked as imported, synced hourly. A re-sync replaces only imported entries, never bookings made here.")}
            </p>
            <.input
              field={@form[:ical_url]}
              type="url"
              label={gettext("Calendar feed URL")}
              placeholder="https://example.com/calendar.ics"
            />
            <div :if={@action == :edit and @service.ical_url} class="flex flex-wrap items-center gap-3 text-sm">
              <button
                type="button"
                class="btn btn-sm"
                phx-click="sync_ical"
                disabled={@syncing}
                id="bookings-sync-ical"
              >
                {if @syncing, do: gettext("Syncing…"), else: gettext("Sync now")}
              </button>
              <span :if={@service.ical_synced_at} class="text-base-content/60">
                {gettext("Last sync: %{at}", at: Format.format_instant(@service.ical_synced_at))}
              </span>
              <span :if={@service.ical_sync_error} class="text-error">
                {@service.ical_sync_error}
              </span>
            </div>
          </div>
        </div>

        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
          <.link navigate={Paths.admin_services()} class="btn btn-ghost">{gettext("Cancel")}</.link>
        </div>
      </.form>

      <div :if={@action == :edit} class="card bg-base-100 shadow-lg">
        <div class="card-body gap-4">
          <h3 class="card-title text-base">{gettext("Availability")}</h3>
          <p class="text-sm text-base-content/60">
            {gettext("No rules = always open. Weekly rules set opening hours; a rule with a date overrides the weekly rules on that date; a closed rule blocks the whole day, and needs no times. With only closed rules, every other day stays open.")}
          </p>

          <table :if={@rules != []} class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Applies to")}</th>
                <th>{gettext("Hours")}</th>
                <th>{gettext("Open?")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={rule <- @rules} id={"rule-#{rule.uuid}"}>
                <td class="text-sm">{rule_scope_label(rule)}</td>
                <td class="text-sm">{rule_hours_label(rule)}</td>
                <td>
                  <span class={if rule.available, do: "badge badge-success", else: "badge badge-error"}>
                    {if rule.available, do: gettext("Open"), else: gettext("Closed")}
                  </span>
                </td>
                <td class="text-right">
                  <button
                    class="btn btn-xs btn-ghost"
                    phx-click="delete_rule"
                    phx-value-uuid={rule.uuid}
                  >
                    {gettext("Remove")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>

          <form
            id="bookings-add-rule"
            phx-submit="add_rule"
            class="flex flex-col gap-3 border-t border-base-200 pt-4"
          >
            <div class="flex flex-wrap items-center gap-3">
              <label
                :for={{num, label} <- weekdays()}
                class="label cursor-pointer gap-1 text-sm"
              >
                <input
                  type="checkbox"
                  name="rule[days_of_week][]"
                  value={num}
                  class="checkbox checkbox-sm"
                />
                {label}
              </label>
            </div>
            <div class="flex flex-wrap items-end gap-3">
              <label class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("Specific date (optional)")}</span>
                <input type="date" name="rule[date]" class="input input-sm" />
              </label>
              <label :if={minutes?(@form)} class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("From")}</span>
                <input type="time" name="rule[start_time]" class="input input-sm" />
              </label>
              <label :if={minutes?(@form)} class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("To")}</span>
                <input type="time" name="rule[end_time]" class="input input-sm" />
              </label>
              <label class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("Kind")}</span>
                <label class="select select-sm">
                  <select name="rule[available]">
                    <option value="true">{gettext("Open")}</option>
                    <option value="false">{gettext("Closed (block out)")}</option>
                  </select>
                </label>
              </label>
              <button type="submit" class="btn btn-sm btn-primary">{gettext("Add rule")}</button>
            </div>
          </form>
        </div>
      </div>

      <div :if={@action == :edit} class="card bg-base-100 shadow-lg">
        <div class="card-body gap-4">
          <h3 class="card-title text-base">{gettext("Named units")}</h3>
          <p class="text-sm text-base-content/60">
            {gettext("Optional: name the individual rooms/chairs/courts. With units, capacity becomes the active-unit count and every booking is auto-assigned a free unit. Without units, the plain capacity number pools.")}
          </p>

          <table :if={@units != []} class="table table-sm">
            <tbody>
              <tr :for={unit <- @units} id={"unit-#{unit.uuid}"}>
                <td class="text-sm">{unit.name}</td>
                <td>
                  <span class={if unit.active, do: "badge badge-success", else: "badge badge-ghost"}>
                    {if unit.active, do: gettext("Active"), else: gettext("Inactive")}
                  </span>
                </td>
                <td class="text-right">
                  <div class="join">
                    <button
                      class="btn btn-xs join-item"
                      phx-click="toggle_unit"
                      phx-value-uuid={unit.uuid}
                    >
                      {if unit.active, do: gettext("Deactivate"), else: gettext("Activate")}
                    </button>
                    <button
                      class="btn btn-xs btn-ghost join-item"
                      phx-click="delete_unit"
                      phx-value-uuid={unit.uuid}
                      data-confirm={gettext("Delete this unit? Past bookings keep their history.")}
                    >
                      {gettext("Delete")}
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>

          <form id="bookings-add-unit" phx-submit="add_unit" class="flex items-end gap-2">
            <label class="fieldset">
              <span class="fieldset-legend text-xs">{gettext("Unit name (e.g. Room 101)")}</span>
              <input type="text" name="unit[name]" class="input input-sm" required />
            </label>
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Add unit")}</button>
          </form>
        </div>
      </div>

      <div :if={@action == :edit} class="card bg-base-100 shadow-lg" id="bookings-price-options">
        <div class="card-body gap-4">
          <h3 class="card-title text-base">{gettext("Price options")}</h3>
          <p class="text-sm text-base-content/60">
            {gettext("Extra rates beside the standard price — a trainer's solo-lesson rate, a members' price. Each says who may book at it; customers see only the options they are entitled to.")}
          </p>

          <table :if={@price_options != []} class="table table-sm">
            <tbody>
              <tr :for={option <- @price_options} id={"price-option-#{option.uuid}"}>
                <td class="text-sm">
                  <div class="font-medium">{option.name}</div>
                  <div class="text-xs text-base-content/50">
                    {Pricing.tag(Pricing.apply_option(@service, option))}
                  </div>
                </td>
                <td class="text-sm">{entitlement_label(option)}</td>
                <td>
                  <span class={if option.active, do: "badge badge-success", else: "badge badge-ghost"}>
                    {if option.active, do: gettext("Active"), else: gettext("Inactive")}
                  </span>
                </td>
                <td class="text-right">
                  <div class="join">
                    <button
                      class="btn btn-xs join-item"
                      phx-click="toggle_price_option"
                      phx-value-uuid={option.uuid}
                    >
                      {if option.active, do: gettext("Deactivate"), else: gettext("Activate")}
                    </button>
                    <button
                      class="btn btn-xs btn-ghost join-item"
                      phx-click="delete_price_option"
                      phx-value-uuid={option.uuid}
                      data-confirm={gettext("Delete this price option? Past bookings keep their total.")}
                    >
                      {gettext("Delete")}
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>

          <form
            id="bookings-add-price-option"
            phx-submit="add_price_option"
            class="flex flex-col gap-3 border-t border-base-200 pt-4"
          >
            <div class="flex flex-wrap items-end gap-3">
              <label class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("Name")}</span>
                <input type="text" name="price_option[name]" class="input input-sm" required />
              </label>
              <label class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("Price")}</span>
                <input
                  type="number"
                  step="0.01"
                  min="0"
                  name="price_option[price]"
                  class="input input-sm w-28"
                  required
                />
              </label>
              <label class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("Per")}</span>
                <label class="select select-sm">
                  <select name="price_option[price_per]">
                    <option value="">{gettext("As the service")}</option>
                    <option value="booking">{gettext("Booking (flat)")}</option>
                    <option value="hour">{gettext("Hour")}</option>
                    <option value="day">{gettext("Day")}</option>
                    <option value="night">{gettext("Night")}</option>
                  </select>
                </label>
              </label>
              <label class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("Who may book at it")}</span>
                <label class="select select-sm">
                  <select name="price_option[entitlement]">
                    <option value="everyone">{gettext("Everyone")}</option>
                    <option value="users">{gettext("Chosen accounts")}</option>
                    <option value="role">{gettext("A role")}</option>
                    <option value="flag">{gettext("Members with a flag")}</option>
                  </select>
                </label>
              </label>
            </div>
            <div class="flex flex-wrap items-end gap-3">
              <label class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("Account emails (chosen accounts)")}</span>
                <input type="text" name="price_option[user_emails]" class="input input-sm" />
              </label>
              <label class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("Role name (a role)")}</span>
                <input type="text" name="price_option[role_name]" class="input input-sm" />
              </label>
              <label class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("Account flag (custom field key)")}</span>
                <input type="text" name="price_option[flag_key]" class="input input-sm" />
              </label>
              <label class="fieldset">
                <span class="fieldset-legend text-xs">{gettext("Description (optional)")}</span>
                <input type="text" name="price_option[description]" class="input input-sm" />
              </label>
              <button type="submit" class="btn btn-sm btn-primary">{gettext("Add price option")}</button>
            </div>
          </form>
        </div>
      </div>

      <div :if={@action == :edit} class="card bg-base-100 shadow-lg" id="bookings-regular-slots">
        <div class="card-body gap-4">
          <h3 class="card-title text-base">{gettext("Regular slots")}</h3>
          <p class="text-sm text-base-content/60">
            {gettext("Who usually has a time. Nobody is blocked: when someone else books into a regular slot, the booking goes through and you are warned.")}
          </p>

          <table :if={@regular_slots != []} class="table table-sm">
            <tbody>
              <tr :for={slot <- @regular_slots} id={"regular-slot-#{slot.uuid}"}>
                <td class="text-sm">{weekday_label(slot.day_of_week)}</td>
                <td class="text-sm">{slot_hours(slot)}</td>
                <td class="text-sm">{slot_holder(slot)}</td>
                <td class="text-right">
                  <button
                    class="btn btn-xs btn-ghost"
                    phx-click="delete_regular_slot"
                    phx-value-uuid={slot.uuid}
                  >
                    {gettext("Remove")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>

          <form
            id="bookings-add-regular-slot"
            phx-submit="add_regular_slot"
            class="flex flex-wrap items-end gap-3 border-t border-base-200 pt-4"
          >
            <label class="fieldset">
              <span class="fieldset-legend text-xs">{gettext("Weekday")}</span>
              <label class="select select-sm">
                <select name="regular_slot[day_of_week]">
                  <option :for={{num, label} <- weekdays()} value={num}>{label}</option>
                </select>
              </label>
            </label>
            <label :if={minutes?(@form)} class="fieldset">
              <span class="fieldset-legend text-xs">{gettext("From")}</span>
              <input type="time" name="regular_slot[start_time]" class="input input-sm" />
            </label>
            <label :if={minutes?(@form)} class="fieldset">
              <span class="fieldset-legend text-xs">{gettext("To")}</span>
              <input type="time" name="regular_slot[end_time]" class="input input-sm" />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend text-xs">{gettext("Regular customer's name")}</span>
              <input type="text" name="regular_slot[customer_name]" class="input input-sm" />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend text-xs">{gettext("Their email")}</span>
              <input type="email" name="regular_slot[customer_email]" class="input input-sm" required />
            </label>
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Add regular slot")}</button>
          </form>
        </div>
      </div>

      <div :if={@action == :new} class="alert">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <span>{gettext("Save the service first — then availability rules can be added here.")}</span>
      </div>
    </div>
    """
  end

  defp rule_scope_label(%{date: %Date{} = date}), do: Format.strftime(date, "%d %b %Y")

  defp rule_scope_label(%{days_of_week: days}) when is_list(days) do
    Enum.map_join(days, ", ", fn num ->
      weekday_label(num)
    end)
  end

  defp rule_scope_label(_), do: "—"

  defp rule_hours_label(%{start_time: %Time{} = s, end_time: %Time{} = e}),
    do: "#{Calendar.strftime(s, "%H:%M")}–#{Calendar.strftime(e, "%H:%M")}"

  defp rule_hours_label(_), do: gettext("whole day")
end
