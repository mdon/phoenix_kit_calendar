defmodule PhoenixKitCalendar.Web.CalendarLiveTest do
  use PhoenixKitCalendar.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCalendar.Events

  @path "/en/admin/calendar"

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitCalendar.enable_system()

    _owner = create_user()
    me = create_user()
    other = create_user()

    %{conn: conn, me: me, other: other}
  end

  defp create_user do
    {:ok, user} =
      Auth.register_user(%{
        email: "callv_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp login(conn, user, perms) do
    put_test_scope(conn, fake_scope(user_uuid: user.uuid, permissions: perms))
  end

  defp scope_of(user, perms), do: fake_scope(user_uuid: user.uuid, permissions: perms)

  defp build_conn_for do
    Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
  end

  defp create_timed(user, title, start_time, end_time) do
    today = Date.utc_today()

    {:ok, event} =
      Events.create_event(scope_of(user, ["calendar"]), user.uuid, %{
        "title" => title,
        "starts_at" => DateTime.new!(today, start_time, "Etc/UTC"),
        "ends_at" => DateTime.new!(today, end_time, "Etc/UTC")
      })

    event
  end

  describe "own calendar" do
    test "renders with the base permission — no layers UI", %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar"])
      {:ok, _view, html} = live(conn, @path)

      assert html =~ "My calendar"
      assert html =~ "New event"
      refute html =~ "Read only"
      # no Calendars panel at all without view_others
      refute html =~ "calendar-people-panel"
    end

    test "shows own events on the month grid", %{conn: conn, me: me} do
      create_timed(me, "Visible standup", ~T[09:00:00], ~T[10:00:00])

      conn = login(conn, me, ["calendar"])
      {:ok, _view, html} = live(conn, @path)

      assert html =~ "Visible standup"
    end

    test "creates an event through the modal form", %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar"])
      {:ok, view, _html} = live(conn, @path)

      view |> element("button", "New event") |> render_click()
      assert render(view) =~ "calendar-event-form"

      today = Date.utc_today()

      html =
        view
        |> form("#calendar-event-form", %{
          "event" => %{
            "title" => "Formed event",
            "all_day" => "false",
            "starts_at" => "#{Date.to_iso8601(today)}T13:00:00",
            "ends_at" => "#{Date.to_iso8601(today)}T14:00:00"
          }
        })
        |> render_submit()

      assert html =~ "Formed event"

      {:ok, [event]} =
        Events.list_events(
          scope_of(me, ["calendar"]),
          me.uuid,
          Date.add(today, -35),
          Date.add(today, 35)
        )

      assert event.title == "Formed event"
      assert event.owner_uuid == me.uuid
    end

    test "?people= is ignored without view_others", %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar"])
      {:ok, _view, html} = live(conn, "#{@path}?people=#{other.uuid}")

      assert html =~ "My calendar"
    end
  end

  describe "the calendars panel (view_others)" do
    test "panel is present (hidden, client-toggled) with search, shortcuts, and badges",
         %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, _view, html} = live(conn, @path)

      # always rendered — opening is a client-side JS toggle (instant),
      # so the content ships with the page
      assert html =~ "calendar-people-panel"
      assert html =~ "Search people"
      assert html =~ "Everyone"
      # fixture users hold no calendar-granting role → lock badge tooltip
      assert html =~ "No calendar access"
      # nobody has events this month yet → empty badges
      assert html =~ "empty"
    end

    test "search narrows the people list", %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element("form[phx-change=search_people]")
        |> render_change(%{"q" => other.email})

      assert html =~ other.email
      refute html =~ "No people match"

      html =
        view
        |> element("form[phx-change=search_people]")
        |> render_change(%{"q" => "match-nothing-xyz"})

      assert html =~ "No people match"
    end

    test "soloing a person shows their calendar read-only without edit_others",
         %{conn: conn, me: me, other: other} do
      create_timed(other, "Their meeting", ~T[11:00:00], ~T[12:00:00])

      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element(~s(button[phx-click=solo_person][phx-value-uuid="#{other.uuid}"]))
        |> render_click()

      assert html =~ "Their meeting"
      assert html =~ "Read only"
      refute html =~ "New event"
    end

    test "soloing with edit_others allows editing and creating",
         %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar", "calendar.view_others", "calendar.edit_others"])
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element(~s(button[phx-click=solo_person][phx-value-uuid="#{other.uuid}"]))
        |> render_click()

      refute html =~ "Read only"
      assert html =~ "New event"
    end
  end

  describe "multi-calendar selection" do
    test "?people=all overlays every calendar, no creation",
         %{conn: conn, me: me, other: other} do
      create_timed(me, "Mine alone", ~T[09:00:00], ~T[10:00:00])
      create_timed(other, "Theirs alone", ~T[11:00:00], ~T[12:00:00])

      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, _view, html} = live(conn, "#{@path}?people=all")

      assert html =~ "Mine alone"
      assert html =~ "Theirs alone"
      assert html =~ "Viewing"
      # no single target calendar → no creation
      refute html =~ "New event"
      assert html =~ "Read only"
    end

    test "unchecking a person narrows the overlay via URL patch",
         %{conn: conn, me: me, other: other} do
      create_timed(me, "Mine alone", ~T[09:00:00], ~T[10:00:00])
      create_timed(other, "Theirs alone", ~T[11:00:00], ~T[12:00:00])

      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, view, html} = live(conn, "#{@path}?people=all")

      assert html =~ "Theirs alone"

      html =
        view
        |> element(~s(input[phx-click=toggle_person][phx-value-uuid="#{other.uuid}"]))
        |> render_click()

      assert html =~ "Mine alone"
      refute html =~ "Theirs alone"
    end

    test "unchecking the last person falls back to the own calendar",
         %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element(~s(input[phx-click=toggle_person][phx-value-uuid="#{me.uuid}"]))
        |> render_click()

      assert html =~ "My calendar"
    end

    test "unknown ids in ?people= are dropped", %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, _view, html} = live(conn, "#{@path}?people=#{Ecto.UUID.generate()}")

      assert html =~ "My calendar"
    end

    test "no view_others → forced to own calendar even via crafted multi URL",
         %{conn: conn, me: me, other: other} do
      create_timed(other, "Secret standup", ~T[09:00:00], ~T[10:00:00])

      conn = login(conn, me, ["calendar"])
      conn2 = login(build_conn_for(), me, ["calendar"])

      {:ok, _view, html} = live(conn, "#{@path}?people=all")
      refute html =~ "Secret standup"

      {:ok, _view, html} = live(conn2, "#{@path}?people=#{other.uuid},#{me.uuid}")
      refute html =~ "Secret standup"
    end
  end
end
