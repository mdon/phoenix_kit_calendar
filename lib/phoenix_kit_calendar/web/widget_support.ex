defmodule PhoenixKitCalendar.Web.WidgetSupport do
  @moduledoc """
  Shared, defensive helpers for the calendar's dashboard widgets.

  Every function here is scoped to the widget VIEWER (via the `scope` the host
  dashboard passes) and fails soft: no scope, a disabled module, or a missing
  table all collapse to an empty result rather than crashing the host — a
  widget must never take the dashboard down with it.

  Times are handled the same way as the rest of the calendar: events are stored
  in UTC and shown in the viewer's offset-hours frame (their `user_timezone`
  setting → site `time_zone` → `"0"`).
  """

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Schemas.Event

  @doc "The viewer's offset-hours timezone string (never raises)."
  @spec viewer_tz(term()) :: String.t()
  def viewer_tz(scope) do
    case scope && scope.user do
      %{user_timezone: tz} when is_binary(tz) and tz != "" -> tz
      %{} = user -> PhoenixKit.Utils.Date.get_user_timezone(user)
      _ -> "0"
    end
  rescue
    _ -> "0"
  end

  @doc "The viewer's user uuid, or nil when there is no authenticated scope."
  @spec viewer_uuid(term()) :: binary() | nil
  def viewer_uuid(scope) do
    with true <- not is_nil(scope),
         uuid when is_binary(uuid) <- Scope.user_uuid(scope) do
      uuid
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "The viewer's LOCAL today (their offset frame), not UTC today."
  @spec local_today(term()) :: Date.t()
  def local_today(scope) do
    DateTime.utc_now()
    |> PhoenixKit.Utils.Date.shift_to_offset(viewer_tz(scope))
    |> DateTime.to_date()
  end

  @doc """
  The viewer's non-cancelled events overlapping `[from, until)` (dates in the
  viewer's frame), through the authorized context path. "Theirs" means the same
  set the main calendar shows a person — events they OWN plus events they are a
  PARTICIPANT in — never anyone else's. Any failure (no scope, disabled module,
  missing table) yields `[]`.
  """
  @spec fetch_events(term(), Date.t(), Date.t()) :: [Event.t()]
  def fetch_events(scope, %Date{} = from, %Date{} = until) do
    tz = viewer_tz(scope)

    with uuid when is_binary(uuid) <- viewer_uuid(scope),
         {:ok, events} <- Events.list_events(scope, uuid, from, until, viewer_tz: tz) do
      Enum.reject(events, &(&1.status == "cancelled"))
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  The list of calendar dates an event occupies in the viewer's frame — used to
  place per-day markers. All-day events use their exclusive DATE end; timed
  events use their shifted local dates, excluding an end that lands exactly on
  local midnight (that boundary belongs to the previous day).
  """
  @spec occupied_dates(Event.t(), String.t()) :: [Date.t()]
  def occupied_dates(%Event{all_day: true} = event, _tz) do
    date_list(event.starts_on, Date.add(event.ends_on, -1))
  end

  def occupied_dates(%Event{} = event, tz) do
    start_dt = PhoenixKit.Utils.Date.shift_to_offset(event.starts_at, tz)
    end_dt = PhoenixKit.Utils.Date.shift_to_offset(event.ends_at, tz)

    start_date = DateTime.to_date(start_dt)
    end_date = DateTime.to_date(end_dt)

    last_date =
      if DateTime.to_time(end_dt) == ~T[00:00:00] and Date.compare(end_date, start_date) == :gt do
        Date.add(end_date, -1)
      else
        end_date
      end

    date_list(start_date, last_date)
  end

  @doc "Whether the event occupies `date` in the viewer's frame."
  @spec on_date?(Event.t(), Date.t(), String.t()) :: boolean()
  def on_date?(event, date, tz), do: Enum.any?(occupied_dates(event, tz), &(&1 == date))

  @doc """
  Chronological sort key. An all-day event sorts at the very start of its day
  (00:00), so events read soonest-first across days AND all-day events lead a
  single day's agenda — one key serves both the Upcoming and Today widgets.
  """
  @spec sort_key(Event.t()) :: DateTime.t()
  def sort_key(%Event{all_day: true} = event),
    do: DateTime.new!(event.starts_on, ~T[00:00:00], "Etc/UTC")

  def sort_key(%Event{} = event), do: event.starts_at

  @doc "Height-based compact flag: a one-row-tall widget renders tighter."
  @spec compact?(term()) :: boolean()
  def compact?(%{h: h}) when is_integer(h), do: h < 2
  def compact?(_), do: false

  # Inclusive date range as a list; empty when the range is inverted.
  defp date_list(%Date{} = from, %Date{} = to) do
    if Date.compare(from, to) == :gt, do: [], else: Enum.to_list(Date.range(from, to))
  end
end
