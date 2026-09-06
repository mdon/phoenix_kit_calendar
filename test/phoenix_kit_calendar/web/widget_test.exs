defmodule PhoenixKitCalendar.Web.WidgetTest do
  @moduledoc """
  The dashboard widgets are the module's most privacy-sensitive host boundary
  (a shared dashboard must never leak one user's events to another). These pin
  the three promises the host relies on: crash-safe nil degradation, strict
  viewer-scoping, and settings consumption.
  """
  use PhoenixKitCalendar.DataCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Web.MiniMonthWidget
  alias PhoenixKitCalendar.Web.TodayAgendaWidget
  alias PhoenixKitCalendar.Web.UpcomingWidget
  alias PhoenixKitCalendar.Web.WidgetSupport

  setup do
    {:ok, _} = PhoenixKitCalendar.enable_system()
    %{alice: create_user(), bob: create_user()}
  end

  defp create_user do
    {:ok, user} =
      Auth.register_user(%{
        email: "widget_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp scope_for(user),
    do: %Scope{user: user, authenticated?: true, cached_permissions: MapSet.new(["calendar"])}

  # A timed event `days` from today on `owner`'s calendar.
  defp event_for(owner, title, days), do: event_on(owner, title, Date.add(Date.utc_today(), days))

  # A timed event on an explicit date on `owner`'s calendar.
  defp event_on(owner, title, %Date{} = date) do
    {:ok, s} = DateTime.new(date, ~T[09:00:00], "Etc/UTC")
    {:ok, e} = DateTime.new(date, ~T[10:00:00], "Etc/UTC")

    {:ok, event} =
      Events.create_event(scope_for(owner), owner.uuid, %{
        "title" => title,
        "all_day" => "false",
        "starts_at" => s,
        "ends_at" => e
      })

    event
  end

  # The same scope with the viewer sitting in `tz` — the widgets read the value
  # straight off the scope's user, so nothing has to be written to the row.
  defp scope_in(user, tz), do: %{scope_for(user) | user: %{user | user_timezone: tz}}

  # An all-day event covering exactly `date` (the stored end is EXCLUSIVE).
  defp all_day_on(owner, title, %Date{} = date) do
    {:ok, event} =
      Events.create_event(scope_for(owner), owner.uuid, %{
        "title" => title,
        "all_day" => "true",
        "starts_on" => Date.to_iso8601(date),
        "ends_on" => Date.to_iso8601(Date.add(date, 1))
      })

    event
  end

  # A one-hour event at `time` as a WALL CLOCK in `tz` — through the same core
  # helper the form uses, so the stored instant is the one a person in `tz`
  # would have typed.
  defp timed_local(owner, title, %Date{} = date, %Time{} = time, tz) do
    {:ok, s} =
      PhoenixKit.Utils.Date.parse_datetime_local(
        "#{Date.to_iso8601(date)}T#{Calendar.strftime(time, "%H:%M")}",
        tz
      )

    {:ok, event} =
      Events.create_event(scope_for(owner), owner.uuid, %{
        "title" => title,
        "all_day" => "false",
        "starts_at" => s,
        "ends_at" => DateTime.add(s, 1, :hour)
      })

    event
  end

  # {earlier, later} dates, both within the 60-day widget horizon, straddling
  # a month boundary so `earlier.day > later.day` (e.g. Jul 31 / Aug 1) — the
  # exact shape that trips a default (day-before-month) term-order sort.
  defp month_crossing_pair do
    today = Date.utc_today()
    boundary_offset = Enum.find(2..59, fn i -> Date.add(today, i).day == 1 end)
    {Date.add(today, boundary_offset - 1), Date.add(today, boundary_offset)}
  end

  describe "nil degradation (a widget must never crash the host)" do
    for {mod, name} <- [
          {UpcomingWidget, "upcoming"},
          {TodayAgendaWidget, "today"},
          {MiniMonthWidget, "mini_month"}
        ] do
      test "#{name} renders with nil scope/settings/size", %{} do
        html = render_component(unquote(mod), id: "w", scope: nil, settings: nil, size: nil)
        assert is_binary(html)
      end
    end

    test "upcoming/today render an empty state, never someone's data, without a scope" do
      up =
        render_component(UpcomingWidget, id: "u", scope: nil, settings: %{}, size: %{w: 3, h: 2})

      td =
        render_component(TodayAgendaWidget,
          id: "t",
          scope: nil,
          settings: %{},
          size: %{w: 3, h: 2}
        )

      assert up =~ "No upcoming events"
      assert td =~ "Nothing scheduled today"
    end
  end

  describe "viewer scoping (never leak another user's events)" do
    test "Upcoming shows the viewer's own events but not another owner's", %{
      alice: alice,
      bob: bob
    } do
      _mine = event_for(alice, "Alice standup", 1)
      _theirs = event_for(bob, "Bob secret 1:1", 1)

      html =
        render_component(UpcomingWidget,
          id: "u",
          scope: scope_for(alice),
          settings: %{},
          size: %{w: 3, h: 3}
        )

      assert html =~ "Alice standup"
      refute html =~ "Bob secret 1:1"
    end

    test "Today shows only the viewer's own today events", %{alice: alice, bob: bob} do
      _mine = event_for(alice, "Alice today", 0)
      _theirs = event_for(bob, "Bob today", 0)

      html =
        render_component(TodayAgendaWidget,
          id: "t",
          scope: scope_for(alice),
          settings: %{},
          size: %{w: 3, h: 3}
        )

      assert html =~ "Alice today"
      refute html =~ "Bob today"
    end
  end

  describe "mini_month sizing (regression: a 6-row month must not be silently clipped)" do
    test "stays scrollable at its declared min_size instead of hard-clipping", %{alice: alice} do
      html =
        render_component(MiniMonthWidget,
          id: "m",
          scope: scope_for(alice),
          settings: %{},
          size: %{w: 8, h: 8}
        )

      # A 6-row month's content can exceed the min_size box; overflow-auto
      # keeps it reachable via scroll instead of overflow-hidden eating rows
      # with no way to recover them.
      assert html =~ ~r/card-body[^"]*overflow-auto/
    end
  end

  describe "views (user-chosen, honored verbatim)" do
    test "Upcoming compact renders one-line rows without the meta line", %{alice: alice} do
      event_for(alice, "Standup", 1)

      detailed =
        render_component(UpcomingWidget,
          id: "u",
          scope: scope_for(alice),
          settings: %{},
          view: "detailed",
          size: %{w: 12, h: 8}
        )

      compact =
        render_component(UpcomingWidget,
          id: "u",
          scope: scope_for(alice),
          settings: %{},
          view: "compact",
          size: %{w: 12, h: 4}
        )

      # (the @container <style> block always contains the selector TEXT, so
      # assert on the meta paragraph's class attribute specifically)
      assert detailed =~ "Standup" and detailed =~ "pk-slot-meta truncate"
      assert compact =~ "Standup"
      refute compact =~ "pk-slot-meta truncate"
    end

    test "an unknown view falls back to detailed", %{alice: alice} do
      event_for(alice, "Standup", 1)

      html =
        render_component(UpcomingWidget,
          id: "u",
          scope: scope_for(alice),
          settings: %{},
          view: "bogus",
          size: %{w: 12, h: 8}
        )

      assert html =~ "pk-slot-meta truncate"
    end

    test "Today compact renders one-line rows without the meta line", %{alice: alice} do
      event_for(alice, "Standup", 0)

      detailed =
        render_component(TodayAgendaWidget,
          id: "t",
          scope: scope_for(alice),
          settings: %{},
          view: "detailed",
          size: %{w: 12, h: 8}
        )

      compact =
        render_component(TodayAgendaWidget,
          id: "t",
          scope: scope_for(alice),
          settings: %{},
          view: "compact",
          size: %{w: 12, h: 4}
        )

      assert detailed =~ "Standup" and detailed =~ "pk-slot-meta truncate"
      assert compact =~ "Standup"
      refute compact =~ "pk-slot-meta truncate"
    end

    test "Today: an unknown view falls back to detailed", %{alice: alice} do
      event_for(alice, "Standup", 0)

      html =
        render_component(TodayAgendaWidget,
          id: "t",
          scope: scope_for(alice),
          settings: %{},
          view: "bogus",
          size: %{w: 12, h: 8}
        )

      assert html =~ "pk-slot-meta truncate"
    end
  end

  describe "settings consumption" do
    test "Upcoming honors the limit setting", %{alice: alice} do
      for i <- 1..4, do: event_for(alice, "Event #{i}", i)

      html =
        render_component(UpcomingWidget,
          id: "u",
          scope: scope_for(alice),
          settings: %{"limit" => "2"},
          size: %{w: 3, h: 3}
        )

      # only the two soonest render
      assert html =~ "Event 1"
      assert html =~ "Event 2"
      refute html =~ "Event 3"
    end

    test "a malformed limit setting falls back instead of crashing", %{alice: alice} do
      _e = event_for(alice, "Still shows", 1)

      html =
        render_component(UpcomingWidget,
          id: "u",
          scope: scope_for(alice),
          settings: %{"limit" => %{}},
          size: %{w: 3, h: 3}
        )

      assert html =~ "Still shows"
    end
  end

  describe "chronological ordering across a month boundary" do
    test "Upcoming stays soonest-first even when day-of-month decreases", %{alice: alice} do
      {earlier, later} = month_crossing_pair()

      # Inserted out of order so a passing test can't be an insertion-order fluke.
      event_on(alice, "Later event", later)
      event_on(alice, "Earlier event", earlier)

      html =
        render_component(UpcomingWidget,
          id: "u",
          scope: scope_for(alice),
          settings: %{},
          size: %{w: 3, h: 3}
        )

      assert html =~ ~r/Earlier event.*Later event/s
    end

    test "Today leads with the all-day rows for a viewer east of UTC", %{alice: alice} do
      # The sort key mixed frames: an all-day event's `starts_on` is a LOCAL
      # date read at 00:00, while a timed event's `starts_at` is a true UTC
      # instant. 02:00 in Tallinn is 23:00Z the day BEFORE, so the standup
      # sorted ahead of the all-day row this widget promises to lead with.
      tz = "Europe/Tallinn"
      scope = scope_in(alice, tz)
      today = WidgetSupport.local_today(scope)

      timed_local(alice, "Early standup", today, ~T[02:00:00], tz)
      all_day_on(alice, "Company offsite", today)

      html =
        render_component(TodayAgendaWidget,
          id: "t",
          scope: scope,
          settings: %{},
          size: %{w: 3, h: 3}
        )

      assert html =~ ~r/Company offsite.*Early standup/s
    end

    test "Upcoming keeps an early-morning event under its own day", %{alice: alice} do
      # Same mismatch across days: tomorrow 02:00 in Tallinn is today 23:00Z,
      # which fell between today's and tomorrow's all-day rows.
      tz = "Europe/Tallinn"
      scope = scope_in(alice, tz)
      today = WidgetSupport.local_today(scope)
      tomorrow = Date.add(today, 1)

      all_day_on(alice, "Today all-day", today)
      timed_local(alice, "Tomorrow dawn", tomorrow, ~T[02:00:00], tz)
      all_day_on(alice, "Tomorrow all-day", tomorrow)

      html =
        render_component(UpcomingWidget,
          id: "u",
          scope: scope,
          settings: %{},
          size: %{w: 3, h: 3}
        )

      assert html =~ ~r/Today all-day.*Tomorrow all-day.*Tomorrow dawn/s
    end
  end
end
