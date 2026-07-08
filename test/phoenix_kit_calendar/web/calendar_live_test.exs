defmodule PhoenixKitCalendar.Web.CalendarLiveTest do
  use PhoenixKitCalendar.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Paths

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

  describe "own calendar" do
    test "renders with the base permission", %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar"])
      {:ok, _view, html} = live(conn, @path)

      assert html =~ "My calendar"
      assert html =~ "New event"
      refute html =~ "Read only"
      # no person switcher without view_others
      refute html =~ "Calendar of"
    end

    test "shows own events on the month grid", %{conn: conn, me: me} do
      today = Date.utc_today()

      {:ok, _} =
        Events.create_event(scope_of(me, ["calendar"]), me.uuid, %{
          "title" => "Visible standup",
          "starts_at" => DateTime.new!(today, ~T[09:00:00], "Etc/UTC"),
          "ends_at" => DateTime.new!(today, ~T[10:00:00], "Etc/UTC")
        })

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
  end

  describe "person switcher and cross-user access" do
    test "view_others shows the switcher and a read-only other calendar",
         %{conn: conn, me: me, other: other} do
      today = Date.utc_today()

      {:ok, _} =
        Events.create_event(scope_of(other, ["calendar"]), other.uuid, %{
          "title" => "Their meeting",
          "starts_at" => DateTime.new!(today, ~T[11:00:00], "Etc/UTC"),
          "ends_at" => DateTime.new!(today, ~T[12:00:00], "Etc/UTC")
        })

      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, view, html} = live(conn, @path)

      assert html =~ "Calendar of"

      # open the other calendar via patch (what the switcher does)
      html =
        view |> element("form[phx-change=switch_user]") |> render_change(%{"user" => other.uuid})

      _ = html

      html = render_patch(view, Paths.for_user(other.uuid))

      assert html =~ "Their meeting"
      assert html =~ "Read only"
      refute html =~ "New event"
    end

    test "edit_others can open and edit another calendar", %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar", "calendar.view_others", "calendar.edit_others"])
      {:ok, view, _html} = live(conn, @path)

      html = render_patch(view, Paths.for_user(other.uuid))
      refute html =~ "Read only"
      assert html =~ "New event"
    end

    test "an unauthorized ?user= param falls back to the own calendar",
         %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar"])
      {:ok, _view, html} = live(conn, "#{@path}?user=#{other.uuid}")

      assert html =~ "My calendar"
    end

    test "switcher annotates users without calendar access", %{conn: conn, me: me} do
      # none of the fixture users hold calendar through a real role, so
      # they all read as "no calendar access" — the annotation the boss
      # asked for (people who lost access still appear).
      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, _view, html} = live(conn, @path)

      assert html =~ "no calendar access"
    end
  end
end
