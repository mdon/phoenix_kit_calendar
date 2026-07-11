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
  end
end
