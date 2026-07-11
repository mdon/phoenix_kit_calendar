defmodule PhoenixKitCalendar.Web.UpcomingWidget do
  @moduledoc """
  Dashboard widget: the viewer's next calendar events, soonest first.

  Rendered by `phoenix_kit_dashboards` (duck-typed contract — see
  `PhoenixKitCalendar.phoenix_kit_widgets/0`). The query is scoped to the
  widget VIEWER's own calendar via the `scope` assign the host passes —
  a shared dashboard never leaks anyone else's events, because each
  viewer sees their own.

  Renders defensively: no scope, no DB, or an unauthorized viewer all
  degrade to a friendly empty state — a widget must never crash the host
  dashboard.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitCalendar.Schemas.Event
  alias PhoenixKitCalendar.Web.WidgetSupport
  alias PhoenixKitWeb.Components.Core.EmptyState

  # How far ahead the widget looks for "upcoming" events.
  @horizon_days 60

  @impl true
  def update(assigns, socket) do
    settings = assigns[:settings] || %{}
    scope = assigns[:scope]
    limit = parse_limit(Map.get(settings, "limit", "5"))

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:show_location, Map.get(settings, "show_location", true) in [true, "true"])
     |> assign(:compact, WidgetSupport.compact?(assigns[:size]))
     |> assign(:viewer_tz, WidgetSupport.viewer_tz(scope))
     |> assign(:events, upcoming_events(scope, limit))}
  end

  # Own-calendar query through the shared, defensive fetch (viewer-scoped, fails
  # soft to []). Drop events already finished, soonest first, cap at the limit.
  defp upcoming_events(scope, limit) do
    today = WidgetSupport.local_today(scope)
    now = DateTime.utc_now()

    scope
    |> WidgetSupport.fetch_events(today, Date.add(today, @horizon_days))
    |> Enum.reject(&past?(&1, now, today))
    |> Enum.sort_by(&WidgetSupport.sort_key/1, DateTime)
    |> Enum.take(limit)
  rescue
    _ -> []
  end

  defp past?(%Event{all_day: true} = event, _now, today),
    do: Date.compare(event.ends_on, today) != :gt

  defp past?(%Event{} = event, now, _today),
    do: DateTime.compare(event.ends_at, now) != :gt

  # Total over any setting value — a corrupt/unexpected setting (e.g. a map)
  # must fall back to the default, never raise into the host dashboard.
  defp parse_limit(value) when is_integer(value) and value > 0, do: min(value, 20)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> min(n, 20)
      _ -> 5
    end
  end

  defp parse_limit(_), do: 5

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card h-full overflow-hidden bg-base-100 flex flex-col">
      <div class={["card-body", (@compact && "p-2 gap-1") || "p-4 gap-2"]}>
        <%= if @events == [] do %>
          <div class="flex items-center justify-center h-full">
            <EmptyState.empty_state
              title={gettext("No upcoming events")}
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
                  {when_label(event, @viewer_tz)}<span :if={@show_location && event.location}>
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

  defp when_label(%Event{all_day: true} = event, _tz) do
    last_day = Date.add(event.ends_on, -1)

    if Date.compare(event.starts_on, last_day) == :eq do
      Calendar.strftime(event.starts_on, "%b %d")
    else
      "#{Calendar.strftime(event.starts_on, "%b %d")} – #{Calendar.strftime(last_day, "%b %d")}"
    end
  end

  defp when_label(%Event{} = event, tz) do
    event.starts_at
    |> PhoenixKit.Utils.Date.shift_to_offset(tz)
    |> Calendar.strftime("%b %d, %H:%M")
  end
end
