defmodule PhoenixKitBookings.Migrations.Schema do
  @moduledoc """
  Versioned migration for the Bookings module.

  Creates the `phoenix_kit_bookings_*` tables: services, availability
  rules, units, holds, waitlist and bookings (V1), plus host profiles, price
  options, events and regular slots (V3). All statements use IF NOT
  EXISTS guards — safe to run multiple times.

  Implements the versioned-migration protocol expected by PhoenixKit Core
  (`mix phoenix_kit.update`): `current_version/0` and
  `migrated_version_runtime/1`. Reference implementation —
  `PhoenixKitStats.Migrations.Schema` in `phoenix_kit_stats`.

  ## Versions

    * **V1** — the tables above (every statement `IF NOT EXISTS`).
    * **V2** — `phoenix_kit_bookings_bookings.time_zone`: the site's zone
      value at the moment a booking was made (an IANA id or a legacy
      offset, as core keeps it). A booking's instants are UTC; the wall
      clock the customer picked lived only in the site's zone at that
      moment, and when that setting moved to IANA ids and the frame turned
      out to have read it as one number, the rows could not be repaired —
      nothing said which zone each was made in. Nullable: rows written
      before V2 hold no answer.
    * **V3** — what the module needs to hold availability that comes from
      somewhere else, and to sell more than one rate:
      - `bookings.source` admits `import`; `external_source` / `external_id`
        on bookings AND availability rules (rules gain `source`
        `manual` / `import`), each with a unique index on
        `(service_uuid, external_source, external_id)` so a re-sync replaces
        only its own rows. An imported booking may carry no customer: the
        name/email NOT NULLs become the `bookings_customer_required` CHECK,
        which still demands both for every non-import row.
      - services: `host_ref` (indexed, a host record such as a machine),
        `bookable_online` (default TRUE; FALSE = show availability only),
        `ical_url` / `ical_synced_at` / `ical_sync_error` (feed import), and
        `host_profile_uuid` (who runs it).
      - `price_options` (per-service rates with an entitlement) and
        `bookings.price_option_uuid`.
      - `host_profiles` (public cards of the people running things) and
        `events` (dated occurrences with a capacity), `bookings.event_uuid`.
      - `regular_slots` (who usually has a weekly time; a booking by someone
        else is flagged to the owner, never refused).

  The applied version is a `bookings_schema:<N>` comment on the services
  table (the CRM/projects chains' convention). A marker-less install whose
  tables exist is V1 — it predates the marker.

  A booking carries either a timed pair (`starts_at`/`ends_at`, minute-unit
  services) or a date pair (`starts_on`/`ends_on`, day/night services) —
  exactly one, enforced by the `bookings_time_shape` CHECK. Both pairs are
  exclusive-end.
  """

  use Ecto.Migration

  @current_version 3
  @marker_prefix "bookings_schema:"
  @version_table "phoenix_kit_bookings_services"

  @doc "Target schema version of the Bookings module."
  def current_version, do: @current_version

  @doc """
  Currently applied schema version, read from the database.

  The `bookings_schema:<N>` marker on the services table when present; a
  marker-less services table reads as `1` (a V1 install predating markers)
  and a missing table as `0`. `opts` is a keyword list with an optional
  `:prefix`.
  """
  def migrated_version_runtime(opts \\ []) do
    # Outside the rescue: an invalid prefix is an error, not "not installed".
    opts |> normalize_prefix() |> read_version()
  end

  # `catch :exit` matters as much as `rescue`: a dead or unstarted pool exits
  # rather than raising, and `mix phoenix_kit.status` asks every module.
  defp read_version(prefix) do
    query = """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: [[@marker_prefix <> n]]}} -> parse_version(n)
      {:ok, %{rows: [[_other_or_nil]]}} -> 1
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 1
    end
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

    # ── V2 ──────────────────────────────────────────────────────────────
    execute("""
    ALTER TABLE #{prefix_str}phoenix_kit_bookings_bookings
      ADD COLUMN IF NOT EXISTS time_zone VARCHAR(64)
    """)

    # ── V3 ──────────────────────────────────────────────────────────────
    up_v3(prefix_str, uuid_default)

    # The marker is stamped last, after every statement it certifies.
    execute(
      "COMMENT ON TABLE #{prefix_str}#{@version_table} IS '#{@marker_prefix}#{@current_version}'"
    )
  end

  @doc """
  Rolls back the Bookings module migration.

  Accepts a keyword list (the form Core passes) or a map, for backward
  compatibility.
  """
  def down(opts \\ []) do
    prefix_str = prefix_str(normalize_prefix(opts))
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    cond do
      target >= @current_version -> :ok
      target == 2 -> down_to_v2(prefix_str)
      target >= 1 -> down_to_v1(prefix_str)
      true -> drop_everything(prefix_str)
    end
  end

  # Statements V3 adds, every one idempotent.
  defp up_v3(p, uuid_default) do
    # Host profiles first: services and events reference them.
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_bookings_host_profiles (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      name VARCHAR(255) NOT NULL,
      slug VARCHAR(160) NOT NULL,
      headline VARCHAR(255),
      bio TEXT,
      photo_url TEXT,
      user_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      provider_uuid UUID,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      position INTEGER NOT NULL DEFAULT 0,
      settings JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT bookings_host_profile_status CHECK (status IN ('active', 'inactive'))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_bookings_host_profiles_slug_index
    ON #{p}phoenix_kit_bookings_host_profiles (slug)
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_bookings_services
      ADD COLUMN IF NOT EXISTS host_ref VARCHAR(255),
      ADD COLUMN IF NOT EXISTS bookable_online BOOLEAN NOT NULL DEFAULT TRUE,
      ADD COLUMN IF NOT EXISTS ical_url TEXT,
      ADD COLUMN IF NOT EXISTS ical_synced_at TIMESTAMPTZ,
      ADD COLUMN IF NOT EXISTS ical_sync_error TEXT,
      ADD COLUMN IF NOT EXISTS host_profile_uuid UUID
        REFERENCES #{p}phoenix_kit_bookings_host_profiles(uuid) ON DELETE SET NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_services_host_ref_index
    ON #{p}phoenix_kit_bookings_services (host_ref)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_services_host_profile_index
    ON #{p}phoenix_kit_bookings_services (host_profile_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_bookings_price_options (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      service_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_bookings_services(uuid) ON DELETE CASCADE,
      name VARCHAR(255) NOT NULL,
      description TEXT,
      price NUMERIC(12,2) NOT NULL,
      price_per VARCHAR(10),
      entitlement VARCHAR(20) NOT NULL DEFAULT 'everyone',
      user_uuids UUID[] NOT NULL DEFAULT '{}',
      role_name VARCHAR(100),
      flag_key VARCHAR(100),
      active BOOLEAN NOT NULL DEFAULT TRUE,
      position INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT bookings_price_option_entitlement
        CHECK (entitlement IN ('everyone', 'users', 'role', 'flag')),
      CONSTRAINT bookings_price_option_price_per
        CHECK (price_per IS NULL OR price_per IN ('booking', 'hour', 'day', 'night')),
      CONSTRAINT bookings_price_option_price CHECK (price >= 0)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_price_options_service_index
    ON #{p}phoenix_kit_bookings_price_options (service_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_bookings_events (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      service_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_bookings_services(uuid) ON DELETE CASCADE,
      host_profile_uuid UUID REFERENCES #{p}phoenix_kit_bookings_host_profiles(uuid) ON DELETE SET NULL,
      title VARCHAR(255) NOT NULL,
      description TEXT,
      location VARCHAR(255),
      starts_at TIMESTAMPTZ NOT NULL,
      ends_at TIMESTAMPTZ NOT NULL,
      capacity INTEGER,
      price NUMERIC(12,2),
      status VARCHAR(20) NOT NULL DEFAULT 'scheduled',
      public BOOLEAN NOT NULL DEFAULT TRUE,
      settings JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT bookings_event_status CHECK (status IN ('scheduled', 'cancelled')),
      CONSTRAINT bookings_event_order CHECK (starts_at < ends_at),
      CONSTRAINT bookings_event_capacity CHECK (capacity IS NULL OR capacity >= 1)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_events_starts_at_index
    ON #{p}phoenix_kit_bookings_events (starts_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_events_service_index
    ON #{p}phoenix_kit_bookings_events (service_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_events_host_profile_index
    ON #{p}phoenix_kit_bookings_events (host_profile_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_bookings_regular_slots (
      uuid UUID PRIMARY KEY DEFAULT #{uuid_default},
      service_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_bookings_services(uuid) ON DELETE CASCADE,
      day_of_week INTEGER NOT NULL,
      start_time TIME,
      end_time TIME,
      user_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      customer_name VARCHAR(255),
      customer_email VARCHAR(255),
      notes TEXT,
      active BOOLEAN NOT NULL DEFAULT TRUE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT bookings_regular_slot_day CHECK (day_of_week BETWEEN 1 AND 7)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_regular_slots_service_index
    ON #{p}phoenix_kit_bookings_regular_slots (service_uuid, day_of_week)
    """)

    # Bookings: the import source, its external ref, price option, event.
    execute("""
    ALTER TABLE #{p}phoenix_kit_bookings_bookings
      ADD COLUMN IF NOT EXISTS external_source VARCHAR(64),
      ADD COLUMN IF NOT EXISTS external_id VARCHAR(255),
      ADD COLUMN IF NOT EXISTS price_option_uuid UUID
        REFERENCES #{p}phoenix_kit_bookings_price_options(uuid) ON DELETE SET NULL,
      ADD COLUMN IF NOT EXISTS event_uuid UUID
        REFERENCES #{p}phoenix_kit_bookings_events(uuid) ON DELETE SET NULL
    """)

    execute(
      "ALTER TABLE #{p}phoenix_kit_bookings_bookings DROP CONSTRAINT IF EXISTS bookings_source"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_bookings_bookings
      ADD CONSTRAINT bookings_source CHECK (source IN ('public', 'admin', 'import'))
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_bookings_bookings
      ALTER COLUMN customer_name DROP NOT NULL,
      ALTER COLUMN customer_email DROP NOT NULL
    """)

    execute(
      "ALTER TABLE #{p}phoenix_kit_bookings_bookings DROP CONSTRAINT IF EXISTS bookings_customer_required"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_bookings_bookings
      ADD CONSTRAINT bookings_customer_required CHECK (
        source = 'import' OR (customer_name IS NOT NULL AND customer_email IS NOT NULL)
      )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_bookings_bookings_external_index
    ON #{p}phoenix_kit_bookings_bookings (service_uuid, external_source, external_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_bookings_bookings_event_index
    ON #{p}phoenix_kit_bookings_bookings (event_uuid)
    """)

    # Availability rules: the same source + external ref.
    execute("""
    ALTER TABLE #{p}phoenix_kit_bookings_availability_rules
      ADD COLUMN IF NOT EXISTS source VARCHAR(20) NOT NULL DEFAULT 'manual',
      ADD COLUMN IF NOT EXISTS external_source VARCHAR(64),
      ADD COLUMN IF NOT EXISTS external_id VARCHAR(255)
    """)

    execute(
      "ALTER TABLE #{p}phoenix_kit_bookings_availability_rules DROP CONSTRAINT IF EXISTS bookings_rule_source"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_bookings_availability_rules
      ADD CONSTRAINT bookings_rule_source CHECK (source IN ('manual', 'import'))
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_bookings_availability_rules_external_index
    ON #{p}phoenix_kit_bookings_availability_rules (service_uuid, external_source, external_id)
    """)
  end

  # Back to V2: V3's tables and columns go. Imported bookings have no place in
  # V2 (its source CHECK and NOT NULL customer columns refuse them), so they
  # are deleted first. Imported availability rules go too: without their
  # `source` column they would pass for the owner's own rules, and a later
  # V3 sync could no longer find them to replace. Every other row survives.
  defp down_to_v2(p) do
    execute("DELETE FROM #{p}phoenix_kit_bookings_bookings WHERE source = 'import'")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{schema_name(p)}'
          AND table_name = 'phoenix_kit_bookings_availability_rules'
          AND column_name = 'source'
      ) THEN
        DELETE FROM #{p}phoenix_kit_bookings_availability_rules WHERE source = 'import';
      END IF;
    END $$;
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_bookings_bookings
      DROP CONSTRAINT IF EXISTS bookings_customer_required,
      DROP CONSTRAINT IF EXISTS bookings_source,
      DROP COLUMN IF EXISTS external_source,
      DROP COLUMN IF EXISTS external_id,
      DROP COLUMN IF EXISTS price_option_uuid,
      DROP COLUMN IF EXISTS event_uuid
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_bookings_bookings
      ADD CONSTRAINT bookings_source CHECK (source IN ('public', 'admin')),
      ALTER COLUMN customer_name SET NOT NULL,
      ALTER COLUMN customer_email SET NOT NULL
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_bookings_availability_rules
      DROP CONSTRAINT IF EXISTS bookings_rule_source,
      DROP COLUMN IF EXISTS source,
      DROP COLUMN IF EXISTS external_source,
      DROP COLUMN IF EXISTS external_id
    """)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_bookings_regular_slots CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_bookings_events CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_bookings_price_options CASCADE")

    execute("""
    ALTER TABLE #{p}phoenix_kit_bookings_services
      DROP COLUMN IF EXISTS host_ref,
      DROP COLUMN IF EXISTS bookable_online,
      DROP COLUMN IF EXISTS ical_url,
      DROP COLUMN IF EXISTS ical_synced_at,
      DROP COLUMN IF EXISTS ical_sync_error,
      DROP COLUMN IF EXISTS host_profile_uuid
    """)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_bookings_host_profiles CASCADE")
    execute("COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}2'")
  end

  # Back to V1: V3 and the V2 column go, the tables stay, the marker says 1.
  defp down_to_v1(prefix_str) do
    down_to_v2(prefix_str)

    execute(
      "ALTER TABLE #{prefix_str}phoenix_kit_bookings_bookings DROP COLUMN IF EXISTS time_zone"
    )

    execute("COMMENT ON TABLE #{prefix_str}#{@version_table} IS '#{@marker_prefix}1'")
  end

  defp drop_everything(prefix_str) do
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_regular_slots CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_bookings CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_waitlist CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_holds CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_units CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_availability_rules CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_events CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_price_options CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_services CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_bookings_host_profiles CASCADE")
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

  # The schema a prefix string names ("" is public).
  defp schema_name(""), do: "public"
  defp schema_name(prefix_str), do: String.trim_trailing(prefix_str, ".")

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
