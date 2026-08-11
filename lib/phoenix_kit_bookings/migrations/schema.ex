defmodule PhoenixKitBookings.Migrations.Schema do
  @moduledoc """
  Versioned migration for the Bookings module.

  Creates the `phoenix_kit_bookings_services`,
  `phoenix_kit_bookings_availability_rules` and
  `phoenix_kit_bookings_bookings` tables. All statements use IF NOT EXISTS
  guards — safe to run multiple times.

  Implements the versioned-migration protocol expected by PhoenixKit Core
  (`mix phoenix_kit.update`): `current_version/0` and
  `migrated_version_runtime/1`. Reference implementation —
  `PhoenixKitStats.Migrations.Schema` in `phoenix_kit_stats`.

  A booking carries either a timed pair (`starts_at`/`ends_at`, minute-unit
  services) or a date pair (`starts_on`/`ends_on`, day/night services) —
  exactly one, enforced by the `bookings_time_shape` CHECK. Both pairs are
  exclusive-end.
  """

  use Ecto.Migration

  @current_version 1

  @doc "Target schema version of the Bookings module."
  def current_version, do: @current_version

  @doc """
  Currently applied schema version, read from the database.

  Returns `0` when the `phoenix_kit_bookings_services` table does not yet
  exist, and `#{@current_version}` once it has been created. `opts` is a
  keyword list with an optional `:prefix`.
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = normalize_prefix(opts)

    table =
      if prefix == "public",
        do: "public.phoenix_kit_bookings_services",
        else: "#{prefix}.phoenix_kit_bookings_services"

    case PhoenixKit.RepoHelper.repo().query("SELECT to_regclass($1)", [table]) do
      {:ok, %{rows: [[nil]]}} -> 0
      {:ok, %{rows: [[_oid]]}} -> @current_version
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc """
  Applies the Bookings module migration.

  Accepts a keyword list (the form Core passes) or a map, for backward
  compatibility.
  """
  def up(opts \\ []) do
    prefix = normalize_prefix(opts)
    prefix_str = prefix_str(prefix)
    uuid_default = uuid_v7_call(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_bookings_services (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      name VARCHAR(255) NOT NULL,
      slug VARCHAR(160) NOT NULL,
      description TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      time_unit VARCHAR(10) NOT NULL DEFAULT 'minutes',
      duration INTEGER NOT NULL DEFAULT 60,
      slot_interval INTEGER,
      flexible_duration BOOLEAN NOT NULL DEFAULT FALSE,
      min_duration INTEGER,
      max_duration INTEGER,
      buffer_before INTEGER NOT NULL DEFAULT 0,
      buffer_after INTEGER NOT NULL DEFAULT 0,
      min_notice INTEGER NOT NULL DEFAULT 0,
      max_advance INTEGER,
      seats INTEGER NOT NULL DEFAULT 1,
      min_stay INTEGER,
      max_stay INTEGER,
      checkin_time TIME,
      checkout_time TIME,
      signup_policy VARCHAR(20) NOT NULL DEFAULT 'anyone',
      require_approval BOOLEAN NOT NULL DEFAULT FALSE,
      owner_uuid UUID REFERENCES #{prefix_str}phoenix_kit_users(uuid) ON DELETE SET NULL,
      cancel_notice INTEGER NOT NULL DEFAULT 0,
      provider_uuid UUID,
      price NUMERIC(12,2),
      price_per VARCHAR(10) NOT NULL DEFAULT 'booking',
      currency VARCHAR(10) NOT NULL DEFAULT 'EUR',
      reminder_minutes INTEGER,
      settings JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT bookings_service_time_unit CHECK (time_unit IN ('minutes', 'day', 'night')),
      CONSTRAINT bookings_service_status CHECK (status IN ('active', 'inactive', 'trashed')),
      CONSTRAINT bookings_service_signup_policy CHECK (signup_policy IN ('anyone', 'login_required')),
      CONSTRAINT bookings_service_seats_positive CHECK (seats >= 1),
      CONSTRAINT bookings_service_duration_positive CHECK (duration >= 1),
      CONSTRAINT bookings_service_price_per CHECK (price_per IN ('booking', 'hour', 'day', 'night'))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_bookings_services_slug_index
    ON #{prefix_str}phoenix_kit_bookings_services (slug)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_services_status_index
    ON #{prefix_str}phoenix_kit_bookings_services (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_services_owner_index
    ON #{prefix_str}phoenix_kit_bookings_services (owner_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_bookings_availability_rules (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      service_uuid UUID NOT NULL REFERENCES #{prefix_str}phoenix_kit_bookings_services(uuid) ON DELETE CASCADE,
      days_of_week INTEGER[],
      date DATE,
      start_time TIME,
      end_time TIME,
      available BOOLEAN NOT NULL DEFAULT TRUE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_availability_rules_service_index
    ON #{prefix_str}phoenix_kit_bookings_availability_rules (service_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_bookings_units (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      service_uuid UUID NOT NULL REFERENCES #{prefix_str}phoenix_kit_bookings_services(uuid) ON DELETE CASCADE,
      name VARCHAR(120) NOT NULL,
      active BOOLEAN NOT NULL DEFAULT TRUE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_units_service_index
    ON #{prefix_str}phoenix_kit_bookings_units (service_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_bookings_holds (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      service_uuid UUID NOT NULL REFERENCES #{prefix_str}phoenix_kit_bookings_services(uuid) ON DELETE CASCADE,
      starts_at TIMESTAMPTZ,
      ends_at TIMESTAMPTZ,
      starts_on DATE,
      ends_on DATE,
      expires_at TIMESTAMPTZ NOT NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT bookings_hold_time_shape CHECK (
        (starts_at IS NOT NULL AND ends_at IS NOT NULL AND starts_on IS NULL AND ends_on IS NULL)
        OR
        (starts_at IS NULL AND ends_at IS NULL AND starts_on IS NOT NULL AND ends_on IS NOT NULL)
      )
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_holds_service_expires_index
    ON #{prefix_str}phoenix_kit_bookings_holds (service_uuid, expires_at)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_bookings_waitlist (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      service_uuid UUID NOT NULL REFERENCES #{prefix_str}phoenix_kit_bookings_services(uuid) ON DELETE CASCADE,
      date DATE NOT NULL,
      customer_name VARCHAR(255) NOT NULL,
      customer_email VARCHAR(255) NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'open',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT bookings_waitlist_status CHECK (status IN ('open', 'notified', 'removed'))
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_waitlist_service_date_index
    ON #{prefix_str}phoenix_kit_bookings_waitlist (service_uuid, date, status)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_bookings_bookings (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      service_uuid UUID NOT NULL REFERENCES #{prefix_str}phoenix_kit_bookings_services(uuid) ON DELETE CASCADE,
      status VARCHAR(20) NOT NULL DEFAULT 'confirmed',
      starts_at TIMESTAMPTZ,
      ends_at TIMESTAMPTZ,
      starts_on DATE,
      ends_on DATE,
      customer_name VARCHAR(255) NOT NULL,
      customer_email VARCHAR(255) NOT NULL,
      customer_phone VARCHAR(50),
      notes TEXT,
      user_uuid UUID REFERENCES #{prefix_str}phoenix_kit_users(uuid) ON DELETE SET NULL,
      unit_uuid UUID REFERENCES #{prefix_str}phoenix_kit_bookings_units(uuid) ON DELETE SET NULL,
      total_price NUMERIC(12,2),
      currency VARCHAR(10),
      source VARCHAR(20) NOT NULL DEFAULT 'public',
      cancelled_at TIMESTAMPTZ,
      cancel_reason TEXT,
      metadata JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT bookings_time_shape CHECK (
        (starts_at IS NOT NULL AND ends_at IS NOT NULL AND starts_on IS NULL AND ends_on IS NULL)
        OR
        (starts_at IS NULL AND ends_at IS NULL AND starts_on IS NOT NULL AND ends_on IS NOT NULL)
      ),
      CONSTRAINT bookings_timed_order CHECK (starts_at IS NULL OR starts_at < ends_at),
      CONSTRAINT bookings_dated_order CHECK (starts_on IS NULL OR starts_on < ends_on),
      CONSTRAINT bookings_status CHECK (status IN ('pending', 'confirmed', 'cancelled')),
      CONSTRAINT bookings_source CHECK (source IN ('public', 'admin'))
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_bookings_service_starts_at_index
    ON #{prefix_str}phoenix_kit_bookings_bookings (service_uuid, starts_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_bookings_service_starts_on_index
    ON #{prefix_str}phoenix_kit_bookings_bookings (service_uuid, starts_on)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_bookings_status_index
    ON #{prefix_str}phoenix_kit_bookings_bookings (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_bookings_user_index
    ON #{prefix_str}phoenix_kit_bookings_bookings (user_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_bookings_customer_email_index
    ON #{prefix_str}phoenix_kit_bookings_bookings (customer_email)
    """)
  end

  @doc """
  Rolls back the Bookings module migration.

  Accepts a keyword list (the form Core passes) or a map, for backward
  compatibility.
  """
  def down(opts \\ []) do
    prefix_str = prefix_str(normalize_prefix(opts))
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_bookings CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_waitlist CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_holds CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_units CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_availability_rules CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_services CASCADE")
  end

  # Core passes a keyword list (`prefix: "public", version: 1`);
  # the legacy mechanism used a map (`%{prefix: "public"}`). Support both.
  defp normalize_prefix(opts) when is_list(opts), do: validate!(opts[:prefix] || "public")
  defp normalize_prefix(%{prefix: prefix}), do: validate!(prefix || "public")
  defp normalize_prefix(_), do: "public"

  # The prefix is interpolated straight into DDL, so it has to be an
  # identifier and nothing else. Core validates its own (`--prefix` →
  # `Helpers.validate_prefix!/1`); a module that skips the check is the one
  # place a crafted prefix reaches the database unescaped.
  defp validate!(prefix) when is_binary(prefix) do
    if prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      prefix
    else
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end
  end

  defp validate!(prefix), do: raise(ArgumentError, "invalid schema prefix: #{inspect(prefix)}")

  defp prefix_str(prefix) when prefix in [nil, "public"], do: ""
  defp prefix_str(prefix), do: "#{prefix}."

  # Always schema-qualified, `public` included.
  #
  # Core installs the generator function into whichever schema it migrated
  # into, so on a named-schema install a BARE call resolves through
  # `search_path` — which does not carry that schema — and the CREATE TABLE
  # fails. Qualifying costs nothing on a public install and is the only
  # thing that works on a prefixed one. Same rule core states for its own
  # chain (`Helpers.uuid_v7_call/1`).
  defp uuid_v7_call(prefix), do: "#{prefix}.uuid_generate_v7()"
end
