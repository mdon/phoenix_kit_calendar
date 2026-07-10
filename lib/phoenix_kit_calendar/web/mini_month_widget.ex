defmodule PhoenixKitCalendar.Web.MiniMonthWidget do
  @moduledoc """
  Dashboard widget: a compact month grid with a dot on each day the viewer has
  an event, today highlighted.

  Rendered by `phoenix_kit_dashboards` (duck-typed contract — see
  `PhoenixKitCalendar.phoenix_kit_widgets/0`). The grid itself is
  `PhoenixLiveCalendar.Components.MiniCalendar`; we only feed it the viewer's
  own events grouped by their LOCAL date (their offset frame), so day markers
  don't drift around UTC midnight and a shared dashboard never leaks anyone
  else's events. Renders defensively — any failure degrades to an empty month.
  """
  use Phoenix.LiveComponent

  alias PhoenixKitCalendar.Web.WidgetSupport
  alias PhoenixLiveCalendar.Components.MiniCalendar

  @impl true
  def update(assigns, socket) do
    scope = assigns[:scope]
    tz = WidgetSupport.viewer_tz(scope)
    today = WidgetSupport.local_today(scope)

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:today, today)
     |> assign(:events_by_date, events_by_date(scope, today, tz))}
  end

  # Group the current month's events by the local dates they occupy. MiniCalendar
  # only counts the per-date list (renders up to three dots), so the list values
  # are the events themselves — no mapping to the rendering lib's struct needed.
  defp events_by_date(scope, today, tz) do
    month_start = Date.beginning_of_month(today)
    month_end = Date.end_of_month(today)

    scope
    |> WidgetSupport.fetch_events(month_start, Date.add(month_end, 1))
    |> Enum.reduce(%{}, fn event, acc ->
      event
      |> WidgetSupport.occupied_dates(tz)
      |> Enum.filter(&in_month?(&1, month_start, month_end))
      |> Enum.reduce(acc, fn date, inner -> Map.update(inner, date, [event], &[event | &1]) end)
    end)
  end

  defp in_month?(date, month_start, month_end) do
    Date.compare(date, month_start) != :lt and Date.compare(date, month_end) != :gt
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card h-full overflow-hidden bg-base-100 flex flex-col">
      <div class="card-body p-3 flex items-center justify-center overflow-auto">
        <MiniCalendar.mini_calendar
          date={@today}
          today={@today}
          events_by_date={@events_by_date}
          class="w-full max-w-xs"
        />
      </div>
    </div>
    """
  end
end
