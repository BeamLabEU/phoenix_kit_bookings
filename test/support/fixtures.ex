defmodule PhoenixKitBookings.Fixtures do
  @moduledoc """
  Test fixtures for the three service archetypes. Names are varied per
  call (unique suffix) so always-default rows can't mask wrong-service
  fallbacks.
  """

  alias PhoenixKitBookings.Services

  def unique_name(base), do: "#{base} #{System.unique_integer([:positive])}"

  @doc "Massage-parlor archetype: fixed 60-min slots on the hour, 1 seat."
  def slot_service_fixture(attrs \\ %{}) do
    {:ok, service} =
      %{
        "name" => unique_name("Massage"),
        "time_unit" => "minutes",
        "duration" => 60,
        "slot_interval" => 60,
        "seats" => 1
      }
      |> Map.merge(attrs)
      |> Services.create_service()

    service
  end

  @doc "Gym archetype: free-form, min 30 minutes, no upper bound, 20 seats."
  def freeform_service_fixture(attrs \\ %{}) do
    {:ok, service} =
      %{
        "name" => unique_name("Gym floor"),
        "time_unit" => "minutes",
        "duration" => 60,
        "flexible_duration" => true,
        "min_duration" => 30,
        "seats" => 20
      }
      |> Map.merge(attrs)
      |> Services.create_service()

    service
  end

  @doc "Hotel archetype: nightly stays, 3 rooms, min 1 night."
  def hotel_service_fixture(attrs \\ %{}) do
    {:ok, service} =
      %{
        "name" => unique_name("Double room"),
        "time_unit" => "night",
        "seats" => 3,
        "checkin_time" => "14:00:00",
        "checkout_time" => "12:00:00"
      }
      |> Map.merge(attrs)
      |> Services.create_service()

    service
  end

  @doc "Weekly business-hours rule (Mon–Fri 09:00–17:00) for a minute service."
  def business_hours_rule_fixture(service, attrs \\ %{}) do
    {:ok, rule} =
      Services.add_rule(
        service,
        Map.merge(
          %{
            "days_of_week" => [1, 2, 3, 4, 5],
            "start_time" => "09:00:00",
            "end_time" => "17:00:00"
          },
          attrs
        )
      )

    rule
  end

  @doc "Customer attrs for the details form."
  def customer_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        "customer_name" => unique_name("Guest"),
        "customer_email" => "guest-#{System.unique_integer([:positive])}@example.com"
      },
      attrs
    )
  end

  @doc "Next occurrence of the given ISO weekday strictly after today."
  def next_weekday(iso_weekday, from \\ Date.utc_today()) do
    date = Date.add(from, 1)

    if Date.day_of_week(date) == iso_weekday do
      date
    else
      next_weekday(iso_weekday, date)
    end
  end
end
