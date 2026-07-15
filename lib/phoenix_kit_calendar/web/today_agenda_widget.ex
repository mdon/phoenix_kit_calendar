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
  use Gettext, backend: PhoenixKitWeb.Gettext

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
     |> assign(:view, (assigns[:view] in ["detailed", "compact"] && assigns[:view]) || "detailed")
     |> assign(:show_location, Map.get(settings, "show_location", true) in [true, "true"])
     |> assign(:events, todays_events(scope, today, tz))}
  end

  defp todays_events(scope, today, tz) do
    scope
    |> WidgetSupport.fetch_events(today, Date.add(today, 1))
    |> Enum.filter(&WidgetSupport.on_date?(&1, today, tz))
    |> Enum.sort_by(&WidgetSupport.sort_key/1, DateTime)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card h-full overflow-hidden bg-base-100 flex flex-col">
      <div class="card-body flex h-full min-h-0 flex-col gap-2 p-3">
        <div class="flex items-baseline justify-between shrink-0">
          <span class="text-sm font-semibold">{Calendar.strftime(@today, "%A")}</span>
          <span class="text-xs text-base-content/60">{Calendar.strftime(@today, "%b %-d")}</span>
        </div>

        <%= if @events == [] do %>
          <div class="flex items-center justify-center flex-1">
            <EmptyState.empty_state
              title={gettext("Nothing scheduled today")}
              icon="hero-calendar-days"
              variant="compact"
            />
          </div>
        <% else %>
          <%!-- N-SLOT self-fit (dashboards contract): the body divides into
          slots (min 4, so one event doesn't poster up) and each row's type
          scales to its slot via cq units — the agenda always fits its box. --%>
          <style>
            @container (max-height: 26px) {
              .pk-slot-meta {
                display: none !important;
              }
            }
          </style>
          <ul class="flex min-h-0 flex-1 flex-col">
            <li
              :for={event <- @events}
              class="flex min-h-0 flex-1 items-center gap-2 min-w-0 overflow-hidden [container-type:size]"
            >
              <span class={["h-[10cqh] w-[10cqh] rounded-full shrink-0", event.color || "bg-primary"]} />
              <div :if={@view == "detailed"} class="min-w-0 flex-1">
                <p
                  class="truncate font-medium leading-tight"
                  style={WidgetSupport.fit_text(11, "34cqh", 15)}
                >
                  {event.title}
                </p>
                <p
                  class="pk-slot-meta truncate leading-tight text-base-content/60"
                  style={WidgetSupport.fit_text(9, "24cqh", 12)}
                >
                  {time_label(event, @viewer_tz)}<span :if={@show_location && event.location}>
                    · {event.location}</span>
                </p>
              </div>
              <%!-- Compact: one line — title left, time right. --%>
              <p
                :if={@view == "compact"}
                class="min-w-0 flex-1 truncate font-medium leading-tight"
                style={WidgetSupport.fit_text(11, "42cqh", 15)}
              >
                {event.title}
              </p>
              <span
                :if={@view == "compact"}
                class="shrink-0 leading-none tabular-nums text-base-content/60"
                style={WidgetSupport.fit_text(9, "32cqh", 12)}
              >
                {time_label(event, @viewer_tz)}
              </span>
            </li>
            <li :for={_pad <- 1..max(4 - length(@events), 0)//1} class="min-h-0 flex-1"></li>
          </ul>
        <% end %>
      </div>
    </div>
    """
  end

  defp time_label(%Event{all_day: true}, _tz), do: gettext("All day")

  defp time_label(%Event{} = event, tz) do
    event.starts_at
    |> PhoenixKit.Utils.Date.shift_to_offset(tz)
    |> Calendar.strftime("%H:%M")
  end
end
