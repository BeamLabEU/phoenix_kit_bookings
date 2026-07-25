defmodule PhoenixKitBookings.Pricing do
  @moduledoc """
  Total computation for a booking request: `price × price_per units`.

  - `"booking"` — flat price regardless of length (any time unit)
  - `"hour"` — minute services; fractional hours price proportionally
  - `"day"` / `"night"` — date services; units = `Date.diff(ends, starts)`

  A `price_per` that doesn't fit the range shape (e.g. `"hour"` on a
  nightly service) degrades to the flat price rather than guessing.
  Returns `nil` for unpriced services — bookings then carry no total.
  """

  alias PhoenixKitBookings.Schemas.Service

  @doc "Total for the validated range, or nil when the service is unpriced."
  def total(%Service{price: nil}, _range), do: nil

  def total(
        %Service{price: price, price_per: "hour"},
        {%DateTime{} = starts_at, %DateTime{} = ends_at}
      ) do
    minutes = div(DateTime.diff(ends_at, starts_at, :second), 60)

    price
    |> Decimal.mult(minutes)
    |> Decimal.div(60)
    |> Decimal.round(2)
  end

  def total(
        %Service{price: price, price_per: per},
        {:dates, %Date{} = starts_on, %Date{} = ends_on}
      )
      when per in ["day", "night"] do
    price
    |> Decimal.mult(Date.diff(ends_on, starts_on))
    |> Decimal.round(2)
  end

  # Flat price — also the degrade path for shape-mismatched price_per.
  def total(%Service{price: price}, _range), do: Decimal.round(price, 2)

  @doc "\"120.00 EUR\" or nil."
  def format(nil, _currency), do: nil
  def format(%Decimal{} = total, currency), do: "#{Decimal.to_string(total)} #{currency}"

  @doc "One-line price tag for a service (\"45.00 EUR / hour\"), nil when unpriced."
  def tag(%Service{price: nil}), do: nil

  def tag(%Service{} = service) do
    per =
      case service.price_per do
        "booking" -> ""
        per -> " / #{per}"
      end

    "#{Decimal.to_string(Decimal.round(service.price, 2))} #{service.currency}#{per}"
  end
end
