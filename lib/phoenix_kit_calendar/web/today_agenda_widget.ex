defmodule PhoenixKitCalendar.Web.TodayAgendaWidget do
  @moduledoc """
  Dashboard widget: the viewer's schedule for today — all-day events first,
  then timed events in chronological order.

  Rendered by `phoenix_kit_dashboards` (duck-typed contract — see
  `PhoenixKitCalendar.phoenix_kit_widgets/0`). Scoped to the widget VIEWER's own
  calendar, so a shared dashboard never leaks anyone else's day. "Today" is the
  viewer's LOCAL today (their offset frame), so it doesn't flip around UTC
  midnight. Renders defensively: any failure degrades to a friendly empty
  state rather than crashing the host dashboard.
  """
  use Phoenix.LiveComponent

  alias PhoenixKitCalendar.Schemas.Event
  alias PhoenixKitCalendar.Web.WidgetSupport
  alias PhoenixKitWeb.Components.Core.EmptyState

  @impl true
  def update(assigns, socket) do
    settings = assigns[:settings] || %{}
    scope = assigns[:scope]
    tz = WidgetSupport.viewer_tz(scope)
    today = WidgetSupport.local_today(scope)

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:today, today)
     |> assign(:viewer_tz, tz)
     |> assign(:show_location, Map.get(settings, "show_location", true) in [true, "true"])
     |> assign(:compact, WidgetSupport.compact?(assigns[:size]))
     |> assign(:events, todays_events(scope, today, tz))}
  end

  defp todays_events(scope, today, tz) do
    scope
    |> WidgetSupport.fetch_events(today, Date.add(today, 1))
    |> Enum.filter(&WidgetSupport.on_date?(&1, today, tz))
    |> Enum.sort_by(&WidgetSupport.sort_key/1)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card h-full overflow-hidden bg-base-100 flex flex-col">
      <div class={["card-body", (@compact && "p-2 gap-1") || "p-4 gap-2"]}>
        <div class="flex items-baseline justify-between shrink-0">
          <span class="text-sm font-semibold">{Calendar.strftime(@today, "%A")}</span>
          <span class="text-xs text-base-content/60">{Calendar.strftime(@today, "%b %-d")}</span>
        </div>

        <%= if @events == [] do %>
          <div class="flex items-center justify-center flex-1">
            <EmptyState.empty_state
              title="Nothing scheduled today"
              icon="hero-calendar-days"
              variant="compact"
            />
          </div>
        <% else %>
          <ul class={["overflow-y-auto", (@compact && "space-y-0.5") || "space-y-1.5"]}>
            <li :for={event <- @events} class="flex items-start gap-2 min-w-0">
              <span class={["mt-1.5 w-2 h-2 rounded-full shrink-0", event.color || "bg-primary"]} />
              <div class="min-w-0">
                <p class="text-sm font-medium truncate">{event.title}</p>
                <p class="text-xs text-base-content/60 truncate">
                  {time_label(event, @viewer_tz)}<span :if={@show_location && event.location}>
                    · {event.location}</span>
                </p>
              </div>
            </li>
          </ul>
        <% end %>
      </div>
    </div>
    """
  end

  defp time_label(%Event{all_day: true}, _tz), do: "All day"

  defp time_label(%Event{} = event, tz) do
    event.starts_at
    |> PhoenixKit.Utils.Date.shift_to_offset(tz)
    |> Calendar.strftime("%H:%M")
  end
end
