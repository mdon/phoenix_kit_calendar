defmodule PhoenixKitCalendar.Web.CalendarLiveTest do
  use PhoenixKitCalendar.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Test.Repo, as: TestRepo

  @path "/en/admin/calendar"

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitCalendar.enable_system()

    _owner = create_user()
    me = create_user()
    other = create_user()

    %{conn: conn, me: me, other: other}
  end

  defp create_user,
    do: create_user_with_email("callv_#{System.unique_integer([:positive])}@example.com")

  defp create_user_with_email(email) do
    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
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

    test "status field is edit-only (Active/Cancelled), absent when creating",
         %{conn: conn, me: me} do
      event = create_timed(me, "Standup", ~T[09:00:00], ~T[10:00:00])
      conn = login(conn, me, ["calendar"])
      {:ok, view, _html} = live(conn, @path)

      # creating: no status field at all (no cancelled-on-create)
      view |> element("button", "New event") |> render_click()
      refute render(view) =~ ~s(name="event[status]")

      # editing: the status field appears, labelled Active/Cancelled
      send(view.pid, {:calendar_event_click, event.uuid})
      html = render(view)
      assert html =~ ~s(name="event[status]")
      assert html =~ "Active"
      assert html =~ "Cancelled"
      refute html =~ "Confirmed"
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

    test "toggling All day carries the dates across instead of clearing", %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar"])
      {:ok, view, _html} = live(conn, @path)

      view |> element("button", "New event") |> render_click()
      today = Date.to_iso8601(Date.utc_today())

      # switch to all-day: the (empty) date fields inherit the datetime dates
      html =
        view
        |> form("#calendar-event-form", %{
          "event" => %{
            "all_day" => "true",
            "starts_at" => "#{today}T09:00",
            "ends_at" => "#{today}T10:00"
          }
        })
        |> render_change()

      assert html =~ ~s(name="event[starts_on]")
      assert html =~ ~s(value="#{today}")
      # the checkbox must render CHECKED (regression: a core attr default
      # used to defeat the field derivation → the box visually unchecked
      # itself one patch after every toggle)
      assert html =~ ~r/type="checkbox"[^>]*checked/
      # ...and the end date shows the INCLUSIVE last day (storage is
      # exclusive; a one-day event today must not display tomorrow)
      assert [_, shown_end] = Regex.run(~r/name="event\[ends_on\]"[^>]*value="([^"]+)"/, html)
      assert shown_end == Date.to_iso8601(Date.utc_today())

      # a later unrelated validate must not shift the displayed date again
      html =
        view
        |> form("#calendar-event-form", %{
          "event" => %{
            "all_day" => "true",
            "title" => "Stable",
            "starts_on" => today,
            "ends_on" => shown_end
          }
        })
        |> render_change()

      assert [_, still] = Regex.run(~r/name="event\[ends_on\]"[^>]*value="([^"]+)"/, html)
      assert still == shown_end

      # switch back to timed: datetime fields derive from the dates
      html =
        view
        |> form("#calendar-event-form", %{
          "event" => %{"all_day" => "false", "starts_on" => today, "ends_on" => today}
        })
        |> render_change()

      assert html =~ ~s(name="event[starts_at]")
      assert html =~ ~s(value="#{today}T09:00)
    end

    test "a timed event ending at exactly midnight carries a single all-day date",
         %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar"])
      {:ok, view, _html} = live(conn, @path)

      view |> element("button", "New event") |> render_click()
      today = Date.utc_today()
      tomorrow = Date.add(today, 1)

      # 23:00 → 00:00 exclusive touches ONLY today; toggling all-day must
      # not gain a day (external review finding)
      html =
        view
        |> form("#calendar-event-form", %{
          "event" => %{
            "all_day" => "true",
            "starts_at" => "#{Date.to_iso8601(today)}T23:00",
            "ends_at" => "#{Date.to_iso8601(tomorrow)}T00:00"
          }
        })
        |> render_change()

      assert [_, shown_end] = Regex.run(~r/name="event\[ends_on\]"[^>]*value="([^"]+)"/, html)
      assert shown_end == Date.to_iso8601(today)
    end

    test "editing an all-day event shows the inclusive last day; an untouched save keeps dates",
         %{conn: conn, me: me} do
      today = Date.utc_today()

      # two-day event: today + tomorrow (exclusive end = today+2)
      {:ok, event} =
        Events.create_event(scope_of(me, ["calendar"]), me.uuid, %{
          "title" => "Offsite",
          "all_day" => "true",
          "starts_on" => Date.to_iso8601(today),
          "ends_on" => Date.to_iso8601(Date.add(today, 2))
        })

      conn = login(conn, me, ["calendar"])
      {:ok, view, _html} = live(conn, @path)

      send(view.pid, {:calendar_event_click, event.uuid})
      html = render(view)

      # the form shows the INCLUSIVE last day (tomorrow), not the stored
      # exclusive date — and not a double-shifted day-short value either
      assert [_, shown] = Regex.run(~r/name="event\[ends_on\]"[^>]*value="([^"]+)"/, html)
      assert shown == Date.to_iso8601(Date.add(today, 1))

      # saving what the form shows must be a no-op on the stored dates
      view
      |> form("#calendar-event-form", %{
        "event" => %{
          "title" => "Offsite",
          "all_day" => "true",
          "starts_on" => Date.to_iso8601(today),
          "ends_on" => shown
        }
      })
      |> render_submit()

      {:ok, saved} = Events.get_event(scope_of(me, ["calendar"]), event.uuid)
      assert saved.ends_on == Date.add(today, 2)
    end

    test "validation errors stay hidden until Save is attempted", %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar"])
      {:ok, view, _html} = live(conn, @path)

      view |> element("button", "New event") |> render_click()

      # editing the form (empty title) shows NO errors yet
      html =
        view
        |> form("#calendar-event-form", %{"event" => %{"title" => ""}})
        |> render_change()

      refute html =~ "blank"

      # first save attempt surfaces them
      html =
        view
        |> form("#calendar-event-form", %{"event" => %{"title" => ""}})
        |> render_submit()

      assert html =~ "blank"

      # and from then on they update live while fixing
      html =
        view
        |> form("#calendar-event-form", %{"event" => %{"title" => "Fixed"}})
        |> render_change()

      refute html =~ "blank"
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

    test "a person created after connecting appears once the panel reloads (not a mount-time copy)",
         %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, view, html} = live(conn, @path)

      # not on the roster yet — mount happened before this user existed
      refute html =~ "brand.new.person"
      new_person = create_user_with_email("brand.new.person@example.com")

      # any interaction that push_patches (handle_params re-runs, per the
      # calendar's own "fresh scope, not a mount-time copy" convention)
      html =
        view
        |> element(~s(button[phx-click=solo_person][phx-value-uuid="#{other.uuid}"]))
        |> render_click()

      assert html =~ "brand.new.person"
      assert new_person.uuid
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
      # creation stays available — it targets the viewer's OWN calendar here
      assert html =~ "New event"
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
    test "?people=all overlays every calendar",
         %{conn: conn, me: me, other: other} do
      create_timed(me, "Mine alone", ~T[09:00:00], ~T[10:00:00])
      create_timed(other, "Theirs alone", ~T[11:00:00], ~T[12:00:00])

      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, _view, html} = live(conn, "#{@path}?people=all")

      assert html =~ "Mine alone"
      assert html =~ "Theirs alone"
      assert html =~ "Viewing"
      assert html =~ "New event"
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

    test "edit_others creates events for another person via the owner picker",
         %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar", "calendar.view_others", "calendar.edit_others"])
      {:ok, view, _html} = live(conn, @path)

      view |> element("button", "New event") |> render_click()
      html = render(view)
      # the picker is present with Me preselected-by-default target
      assert html =~ ~s(name="owner")

      today = Date.utc_today()

      view
      |> form("#calendar-event-form", %{
        "owner" => other.uuid,
        "event" => %{
          "title" => "Delegated briefing",
          "all_day" => "false",
          "starts_at" => "#{Date.to_iso8601(today)}T15:00:00",
          "ends_at" => "#{Date.to_iso8601(today)}T16:00:00"
        }
      })
      |> render_submit()

      {:ok, [event]} =
        Events.list_events(
          scope_of(other, ["calendar"]),
          other.uuid,
          Date.add(today, -35),
          Date.add(today, 35)
        )

      assert event.title == "Delegated briefing"
      assert event.owner_uuid == other.uuid
    end

    test "picking a target outside the current view shows the warning",
         %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar", "calendar.view_others", "calendar.edit_others"])
      {:ok, view, _html} = live(conn, @path)

      view |> element("button", "New event") |> render_click()

      # default target (Me) IS the current view — no warning
      refute render(view) =~ "won&#39;t appear here"

      # switch the target to someone not in view
      html =
        view
        |> form("#calendar-event-form", %{"owner" => other.uuid, "event" => %{"title" => "x"}})
        |> render_change()

      assert html =~ "won&#39;t appear here"
    end

    test "without edit_others a crafted owner param is sanitized to self",
         %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, view, _html} = live(conn, @path)

      view |> element("button", "New event") |> render_click()
      # no picker without edit_others
      refute render(view) =~ ~s(name="owner")

      today = Date.utc_today()

      render_submit(view, "save_event", %{
        "owner" => other.uuid,
        "event" => %{
          "title" => "Smuggled",
          "all_day" => "false",
          "starts_at" => "#{Date.to_iso8601(today)}T15:00:00",
          "ends_at" => "#{Date.to_iso8601(today)}T16:00:00"
        }
      })

      # landed on the CALLER's calendar, not the crafted target
      {:ok, other_events} =
        Events.list_events(
          scope_of(other, ["calendar"]),
          other.uuid,
          Date.add(today, -35),
          Date.add(today, 35)
        )

      assert other_events == []

      {:ok, [event]} =
        Events.list_events(
          scope_of(me, ["calendar"]),
          me.uuid,
          Date.add(today, -35),
          Date.add(today, 35)
        )

      assert event.title == "Smuggled"
      assert event.owner_uuid == me.uuid
    end

    test "creating while viewing someone else read-only targets self with a warning",
         %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, view, _html} = live(conn, "#{@path}?people=#{other.uuid}")

      view |> element("button", "New event") |> render_click()
      html = render(view)

      # no owner picker without edit_others — and no read-only filler row
      # either (the event silently targets your own calendar)
      refute html =~ ~s(name="owner")
      # own calendar is not part of the current view → warned
      assert html =~ "won&#39;t appear here"
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

  describe "timezones (UTC storage, viewer-frame display)" do
    test "typed times are the viewer's local; storage is UTC; display round-trips",
         %{conn: conn, me: me} do
      conn =
        put_test_scope(
          conn,
          fake_scope(user_uuid: me.uuid, permissions: ["calendar"], user_timezone: "3")
        )

      {:ok, view, _} = live(conn, @path)

      view |> element("button", "New event") |> render_click()
      today = Date.to_iso8601(Date.utc_today())

      view
      |> form("#calendar-event-form", %{
        "event" => %{
          "title" => "Morning sync",
          "all_day" => "false",
          "starts_at" => "#{today}T09:00",
          "ends_at" => "#{today}T10:00"
        }
      })
      |> render_submit()

      {:ok, [event]} =
        Events.list_events(
          scope_of(me, ["calendar"]),
          me.uuid,
          Date.add(Date.utc_today(), -35),
          Date.add(Date.utc_today(), 35)
        )

      # 09:00 at UTC+3 = 06:00 UTC in storage
      assert event.starts_at == DateTime.new!(Date.utc_today(), ~T[06:00:00], "Etc/UTC")

      # ...and the edit form shows 09:00 again (viewer frame)
      send(view.pid, {:calendar_event_click, event.uuid})
      html = render(view)
      assert html =~ ~s(value="#{today}T09:00")
    end

    test "editing another person's calendar shows the cross-timezone indicator + frame switch",
         %{conn: conn, me: me, other: other} do
      # the target owner lives at UTC+1 (persisted), the editor at UTC+3
      {:ok, other_bin} = Ecto.UUID.dump(other.uuid)

      TestRepo.update_all(
        from(u in "phoenix_kit_users", where: u.uuid == ^other_bin),
        set: [user_timezone: "1"]
      )

      event =
        Events.create_event(scope_of(other, ["calendar"]), other.uuid, %{
          "title" => "Their standup",
          "starts_at" => DateTime.new!(Date.utc_today(), ~T[06:00:00], "Etc/UTC"),
          "ends_at" => DateTime.new!(Date.utc_today(), ~T[07:00:00], "Etc/UTC")
        })
        |> then(fn {:ok, e} -> e end)

      conn =
        put_test_scope(
          conn,
          fake_scope(
            user_uuid: me.uuid,
            permissions: ["calendar", "calendar.view_others", "calendar.edit_others"],
            user_timezone: "3"
          )
        )

      {:ok, view, _} = live(conn, @path)
      send(view.pid, {:calendar_event_click, event.uuid})
      html = render(view)

      today = Date.to_iso8601(Date.utc_today())
      # indicator names both offsets; times default to the VIEWER's frame
      assert html =~ "UTC+1"
      assert html =~ "UTC+3"
      assert html =~ ~s(name="owner_tz_entry")
      assert html =~ ~s(value="#{today}T09:00")

      # switching to the owner's frame re-renders the SAME instant at UTC+1
      html =
        view
        |> form("#calendar-event-form", %{
          "owner_tz_entry" => "true",
          "event" => %{
            "title" => "Their standup",
            "all_day" => "false",
            "starts_at" => "#{today}T09:00",
            "ends_at" => "#{today}T10:00"
          }
        })
        |> render_change()

      assert html =~ ~s(value="#{today}T07:00")

      # saving what the form shows (owner frame) keeps the stored instant
      view
      |> form("#calendar-event-form", %{
        "owner_tz_entry" => "true",
        "event" => %{
          "title" => "Their standup",
          "all_day" => "false",
          "starts_at" => "#{today}T07:00",
          "ends_at" => "#{today}T08:00"
        }
      })
      |> render_submit()

      {:ok, saved} =
        Events.get_event(scope_of(me, ["calendar", "calendar.edit_others"]), event.uuid)

      assert saved.starts_at == DateTime.new!(Date.utc_today(), ~T[06:00:00], "Etc/UTC")
    end

    test "same-timezone calendars show no indicator", %{conn: conn, me: me} do
      conn =
        put_test_scope(
          conn,
          fake_scope(user_uuid: me.uuid, permissions: ["calendar"], user_timezone: "3")
        )

      {:ok, view, _} = live(conn, @path)

      view |> element("button", "New event") |> render_click()
      refute render(view) =~ ~s(name="owner_tz_entry")
    end
  end

  defmodule FakeLocations do
    def module_key, do: "locations"
    def module_name, do: "Fake Locations"
    def enabled?, do: true

    def permission_metadata,
      do: %{key: "locations", label: "Locations", icon: "hero-map-pin", description: ""}
  end

  describe "restore_event_draft (reconnect recovery)" do
    test "rebuilds a NEW event modal from a client draft", %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar"])
      {:ok, view, _} = live(conn, @path)
      today = Date.to_iso8601(Date.utc_today())

      # the draft the PkDialogDraft hook would push after a reconnect
      render_hook(view, "restore_event_draft", %{
        "key" => "new",
        "event" => %{
          "title" => "Recovered draft",
          "all_day" => "false",
          "starts_at" => "#{today}T09:00",
          "ends_at" => "#{today}T10:00",
          "color" => "bg-pink-500"
        }
      })

      html = render(view)
      # the modal is open with the editable form and the typed data restored
      assert html =~ "calendar-event-form"
      assert html =~ ~s(value="Recovered draft")
      assert html =~ ~r/name="event\[color\]" value="bg-pink-500" checked/
    end

    test "an EDIT draft re-fetches and re-authorizes — no acting on an un-editable event",
         %{conn: conn, me: me, other: other} do
      event = create_timed(other, "Their private event", ~T[09:00:00], ~T[10:00:00])

      # me has only my own calendar — a draft keyed to other's event must not
      # let me edit it; it falls back to a NEW event (editing_event nil)
      conn = login(conn, me, ["calendar"])
      {:ok, view, _} = live(conn, @path)

      render_hook(view, "restore_event_draft", %{
        "key" => event.uuid,
        "event" => %{"title" => "Hijack attempt", "all_day" => "false"}
      })

      html = render(view)
      # not editing their event (no Delete button, which only shows for an
      # editable existing event); the draft title is kept as a new event
      assert html =~ "New event"
      refute html =~ "Their private event"
    end

    test "a malformed draft payload is ignored", %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar"])
      {:ok, view, _} = live(conn, @path)

      render_hook(view, "restore_event_draft", %{"event" => "not-a-map"})
      assert render(view) =~ "My calendar"
    end
  end

  describe "malformed payloads don't crash the socket" do
    test "forged toggle_person / save_event / event-click payloads are ignored",
         %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar", "calendar.view_others"])
      {:ok, view, _} = live(conn, @path)

      # non-string uuid would later crash Enum.join on the selection
      render_hook(view, "toggle_person", %{"uuid" => %{"evil" => true}})
      render_hook(view, "solo_person", %{"uuid" => 123})
      # non-map event payload
      render_hook(view, "save_event", %{"event" => "not-a-map"})
      render_hook(view, "validate_event", %{"event" => ["x"]})
      # forged, non-UUID event id → get_event must not raise
      send(view.pid, {:calendar_event_click, "not-a-uuid"})

      # socket is still alive and rendering
      assert render(view) =~ "My calendar"
    end
  end

  # The pickers are core SearchPicker hooks — the dropdown is client-side;
  # these cover the server half of the contract (search → push_event rows,
  # pick/text → chip + staged confirmation).
  describe "modal pickers (SearchPicker events)" do
    test "participant_search answers with flattened icon-tagged rows, excluding pending",
         %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar", "calendar.invite_platform_users"])
      {:ok, view, _} = live(conn, @path)
      view |> element("button", "New event") |> render_click()

      render_hook(view, "participant_search", %{"q" => other.email, "limit" => 8})

      assert_push_event(view, "calendar_participant_results", %{q: q, results: results})
      assert q == other.email
      assert [%{kind: "user", uuid: uuid, icon: "hero-user", sublabel: "Users"}] = results
      assert uuid == other.uuid

      # spoofed label is accepted for the chip (canonicalized at save time)
      render_hook(view, "add_participant", %{
        "kind" => "user",
        "uuid" => other.uuid,
        "label" => other.email
      })

      assert_push_event(view, "calendar_participant_staged", %{})
      assert render(view) =~ other.email

      # already-pending entries drop out of subsequent searches
      render_hook(view, "participant_search", %{"q" => other.email, "limit" => 8})
      assert_push_event(view, "calendar_participant_results", %{results: []})
    end

    test "a disallowed kind is ignored but still confirms staging (hook must clear)",
         %{conn: conn, me: me, other: other} do
      conn = login(conn, me, ["calendar"])
      {:ok, view, _} = live(conn, @path)
      view |> element("button", "New event") |> render_click()

      render_hook(view, "add_participant", %{
        "kind" => "user",
        "uuid" => other.uuid,
        "label" => "Sneaky"
      })

      assert_push_event(view, "calendar_participant_staged", %{})
      refute render(view) =~ "Sneaky"
    end

    test "free text stages a chip via the picker's text event", %{conn: conn, me: me} do
      conn = login(conn, me, ["calendar"])
      {:ok, view, _} = live(conn, @path)
      view |> element("button", "New event") |> render_click()

      render_hook(view, "add_free_text_participant", %{"name" => "  Granny  "})

      assert_push_event(view, "calendar_participant_staged", %{})
      assert render(view) =~ "Granny"
    end

    test "location picker renders + searches stored locations when the module is on",
         %{conn: conn, me: me} do
      PhoenixKit.ModuleRegistry.register(FakeLocations)
      on_exit(fn -> PhoenixKit.ModuleRegistry.unregister(FakeLocations) end)
      seed_location("Meeting Room 4")
      seed_location("Rooftop")

      conn = login(conn, me, ["calendar"])
      {:ok, view, _} = live(conn, @path)
      view |> element("button", "New event") |> render_click()

      html = render(view)
      assert html =~ "calendar-location-picker"
      assert html =~ "data-search-on-focus"

      # empty query = the full list (the hook searches on focus/click)
      render_hook(view, "location_search", %{"q" => "", "limit" => 8})

      assert_push_event(view, "calendar_location_results", %{q: "", results: results})
      assert Enum.map(results, & &1.label) == ["Meeting Room 4", "Rooftop"]
      assert Enum.all?(results, &(&1.icon == "hero-map-pin"))

      render_hook(view, "location_search", %{"q" => "roof", "limit" => 8})
      assert_push_event(view, "calendar_location_results", %{q: "roof", results: [one]})
      assert one.label == "Rooftop"
    end

    test "without the locations module the field is a plain input", %{conn: conn, me: me} do
      seed_location("Invisible HQ")

      conn = login(conn, me, ["calendar"])
      {:ok, view, _} = live(conn, @path)
      view |> element("button", "New event") |> render_click()

      html = render(view)
      refute html =~ "calendar-location-picker"
      assert html =~ ~s(name="event[location]")
    end
  end

  defp seed_location(name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, uuid_bin} = Ecto.UUID.dump(Ecto.UUID.generate())

    {1, _} =
      TestRepo.insert_all("phoenix_kit_locations", [
        %{uuid: uuid_bin, name: name, inserted_at: now, updated_at: now}
      ])

    :ok
  end
end
