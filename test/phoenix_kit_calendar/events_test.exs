defmodule PhoenixKitCalendar.EventsTest do
  @moduledoc """
  The authorization core of the module: every combination of
  own/other-calendar × view/edit intent × permission set, plus the two
  ownership invariants (owner never from attrs, owner immutable).
  """
  use PhoenixKitCalendar.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Schemas.Event

  setup do
    # Scope.can?/2 requires the module to be enabled (live check).
    {:ok, _} = PhoenixKitCalendar.enable_system()

    # Real users — events carry a real FK to phoenix_kit_users.
    _owner = create_user()
    alice = create_user()
    bob = create_user()

    %{alice: alice, bob: bob}
  end

  defp create_user do
    {:ok, user} =
      Auth.register_user(%{
        email: "cal_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  # A scope with a precise permission set — cached_roles deliberately a
  # plain custom role so no system-role behavior interferes.
  defp scope_for(user, perms) do
    %Scope{
      user: user,
      authenticated?: true,
      cached_roles: ["Employee"],
      cached_permissions: MapSet.new(perms)
    }
  end

  defp timed_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "Meeting",
        "starts_at" => "2026-07-10T09:00:00Z",
        "ends_at" => "2026-07-10T10:00:00Z"
      },
      overrides
    )
  end

  # A Tallinn wall clock → the UTC instant, from the tz database itself so the
  # expected values are not hand-copied offsets.
  defp tallinn_to_utc(%NaiveDateTime{} = local) do
    local
    |> DateTime.from_naive!("Europe/Tallinn", Tz.TimeZoneDatabase)
    |> DateTime.shift_zone!("Etc/UTC", Tz.TimeZoneDatabase)
  end

  describe "create_event/4 authorization" do
    test "own calendar with the base key succeeds", %{alice: alice} do
      scope = scope_for(alice, ["calendar"])

      assert {:ok, %Event{} = event} = Events.create_event(scope, alice.uuid, timed_attrs())
      assert event.owner_uuid == alice.uuid
    end

    test "own calendar without the base key is unauthorized", %{alice: alice} do
      scope = scope_for(alice, [])
      assert {:error, :unauthorized} = Events.create_event(scope, alice.uuid, timed_attrs())
    end

    test "someone else's calendar needs edit_others", %{alice: alice, bob: bob} do
      base_only = scope_for(alice, ["calendar"])
      viewer = scope_for(alice, ["calendar", "calendar.view_others"])
      editor = scope_for(alice, ["calendar", "calendar.edit_others"])

      assert {:error, :unauthorized} = Events.create_event(base_only, bob.uuid, timed_attrs())
      assert {:error, :unauthorized} = Events.create_event(viewer, bob.uuid, timed_attrs())
      assert {:ok, event} = Events.create_event(editor, bob.uuid, timed_attrs())
      assert event.owner_uuid == bob.uuid
    end

    test "owner_uuid in attrs is ignored — the authorized argument wins",
         %{alice: alice, bob: bob} do
      scope = scope_for(alice, ["calendar"])
      attrs = timed_attrs(%{"owner_uuid" => bob.uuid})

      assert {:ok, event} = Events.create_event(scope, alice.uuid, attrs)
      assert event.owner_uuid == alice.uuid
    end

    test "everything is unauthorized while the module is disabled", %{alice: alice} do
      {:ok, _} = PhoenixKitCalendar.disable_system()
      scope = scope_for(alice, ["calendar"])

      assert {:error, :unauthorized} = Events.create_event(scope, alice.uuid, timed_attrs())
    end
  end

  describe "update_event/4 and delete_event/3 (load-then-authorize)" do
    setup %{alice: alice, bob: bob} do
      {:ok, event} =
        Events.create_event(scope_for(bob, ["calendar"]), bob.uuid, timed_attrs())

      %{event: event, alice: alice, bob: bob}
    end

    test "the persisted owner decides — view_others cannot write", %{
      alice: alice,
      event: event
    } do
      viewer = scope_for(alice, ["calendar", "calendar.view_others"])

      assert {:error, :unauthorized} = Events.update_event(viewer, event, %{"title" => "X"})
      assert {:error, :unauthorized} = Events.delete_event(viewer, event)
    end

    test "edit_others can write to someone else's event", %{alice: alice, event: event} do
      editor = scope_for(alice, ["calendar", "calendar.edit_others"])

      assert {:ok, updated} = Events.update_event(editor, event, %{"title" => "Rescheduled"})
      assert updated.title == "Rescheduled"
      assert {:ok, _} = Events.delete_event(editor, updated)
    end

    test "the owner can edit their own event", %{bob: bob, event: event} do
      scope = scope_for(bob, ["calendar"])
      assert {:ok, updated} = Events.update_event(scope, event, %{"title" => "Mine"})
      assert updated.title == "Mine"
    end

    test "an update cannot move the event to another calendar", %{
      alice: alice,
      bob: bob,
      event: event
    } do
      # even a fully-privileged editor can't transfer ownership
      editor = scope_for(alice, ["calendar", "calendar.edit_others"])

      assert {:ok, updated} =
               Events.update_event(editor, event, %{
                 "title" => "Steal",
                 "owner_uuid" => alice.uuid
               })

      assert updated.owner_uuid == bob.uuid
    end

    test "authorization uses the PERSISTED owner, not a forged in-memory struct",
         %{alice: alice, bob: bob, event: event} do
      # Alice holds only her own calendar. A struct claiming SHE owns Bob's
      # event must not let her mutate the real row (which Ecto keys by uuid).
      forged = %{event | owner_uuid: alice.uuid}
      alice_scope = scope_for(alice, ["calendar"])

      assert {:error, :unauthorized} =
               Events.update_event(alice_scope, forged, %{"title" => "Pwned"})

      assert {:error, :unauthorized} = Events.delete_event(alice_scope, forged)

      # Bob's row is untouched
      {:ok, reloaded} = Events.get_event(scope_for(bob, ["calendar"]), event.uuid)
      assert reloaded.title == event.title
      assert reloaded.owner_uuid == bob.uuid
    end

    test "updating a since-deleted event returns :not_found, not a crash",
         %{bob: bob, event: event} do
      scope = scope_for(bob, ["calendar"])
      {:ok, _} = Events.delete_event(scope, event)

      assert {:error, :not_found} = Events.update_event(scope, event, %{"title" => "Zombie"})
    end
  end

  describe "list_events/4" do
    test "returns own events inside the window, excludes outside", %{alice: alice} do
      scope = scope_for(alice, ["calendar"])

      {:ok, inside} = Events.create_event(scope, alice.uuid, timed_attrs())

      {:ok, _outside} =
        Events.create_event(
          scope,
          alice.uuid,
          timed_attrs(%{
            "starts_at" => "2026-09-01T09:00:00Z",
            "ends_at" => "2026-09-01T10:00:00Z"
          })
        )

      {:ok, events} = Events.list_events(scope, alice.uuid, ~D[2026-07-01], ~D[2026-08-01])
      assert Enum.map(events, & &1.uuid) == [inside.uuid]
    end

    test "a timed event near UTC midnight lands in the viewer-local window",
         %{alice: alice} do
      scope = scope_for(alice, ["calendar"])

      # stored 2026-06-30 22:00 UTC — which is 2026-07-01 01:00 for a UTC+3
      # viewer, so it belongs on July 1 in their grid
      {:ok, event} =
        Events.create_event(scope, alice.uuid, %{
          "title" => "Late night",
          "starts_at" => "2026-06-30T22:00:00Z",
          "ends_at" => "2026-06-30T23:00:00Z"
        })

      # UTC-framed query for July excludes it (it's June 30 in UTC)
      {:ok, utc} = Events.list_events(scope, alice.uuid, ~D[2026-07-01], ~D[2026-08-01])
      refute event.uuid in Enum.map(utc, & &1.uuid)

      # the viewer-local (UTC+3) window includes it, matching the grid
      {:ok, local} =
        Events.list_events(scope, alice.uuid, ~D[2026-07-01], ~D[2026-08-01], viewer_tz: "3")

      assert event.uuid in Enum.map(local, & &1.uuid)
    end

    test "the viewer-local window follows the zone's offset ON THE DATE, not today's",
         %{alice: alice} do
      scope = scope_for(alice, ["calendar"])

      # Europe/Tallinn is UTC+2 in January and UTC+3 in July. Whichever season
      # the suite runs in, one of these two months sits across a
      # daylight-saving switch from "now" — where a snapshot of today's offset
      # applied to both bounds shifts the whole window by an hour: the last
      # local hour of the month falls out, and the last hour of the previous
      # month leaks in (or the first hours, in the other direction).
      #
      # Four probes per month, each 30 minutes long: the first and last local
      # half hour INSIDE the month, and the half hours just before and after.
      probes =
        for {month, from, until} <- [
              {:january, ~D[2026-01-01], ~D[2026-02-01]},
              {:july, ~D[2026-07-01], ~D[2026-08-01]}
            ],
            {label, local_start} <- [
              {:before, NaiveDateTime.new!(Date.add(from, -1), ~T[23:30:00])},
              {:first, NaiveDateTime.new!(from, ~T[00:30:00])},
              {:last, NaiveDateTime.new!(Date.add(until, -1), ~T[23:30:00])},
              {:after, NaiveDateTime.new!(until, ~T[00:30:00])}
            ] do
          starts_at = tallinn_to_utc(local_start)

          {:ok, event} =
            Events.create_event(scope, alice.uuid, %{
              "title" => "#{month} #{label}",
              "starts_at" => DateTime.to_iso8601(starts_at),
              "ends_at" => DateTime.to_iso8601(DateTime.add(starts_at, 30, :minute))
            })

          {{month, label}, event.uuid}
        end
        |> Map.new()

      for {month, from, until} <- [
            {:january, ~D[2026-01-01], ~D[2026-02-01]},
            {:july, ~D[2026-07-01], ~D[2026-08-01]}
          ] do
        {:ok, events} =
          Events.list_events(scope, alice.uuid, from, until, viewer_tz: "Europe/Tallinn")

        assert Enum.map(events, & &1.uuid) |> Enum.sort() ==
                 Enum.sort([probes[{month, :first}], probes[{month, :last}]]),
               "#{month}: expected exactly the first and last local half hours"
      end
    end

    test "zones that switch AT midnight keep the repeated or skipped hour on the right day",
         %{alice: alice} do
      scope = scope_for(alice, ["calendar"])

      # Havana falls back 2026-11-01 01:00 → 00:00, so 00:00–01:00 Nov 1 happens
      # twice (04:00Z–06:00Z). Both belong to Nov 1: local midnight resolves to
      # the FIRST 00:00. Santiago falls back 2026-04-05 00:00 → 23:00 Apr 4, so
      # 23:00–00:00 Apr 4 happens twice (02:00Z–04:00Z) and Apr 5 starts at
      # 04:00Z; it springs forward 2026-09-06 00:00 → 01:00, so Sep 6 has no
      # 00:00 and starts at 01:00 (04:00Z).
      cases = [
        {"America/Havana", ~D[2026-11-01], ~U[2026-11-01 04:30:00Z], :inside},
        {"America/Havana", ~D[2026-11-01], ~U[2026-11-01 05:30:00Z], :inside},
        {"America/Havana", ~D[2026-11-01], ~U[2026-11-01 03:30:00Z], :day_before},
        {"America/Santiago", ~D[2026-04-05], ~U[2026-04-05 03:30:00Z], :day_before},
        {"America/Santiago", ~D[2026-04-05], ~U[2026-04-05 04:30:00Z], :inside},
        {"America/Santiago", ~D[2026-09-06], ~U[2026-09-06 03:30:00Z], :day_before},
        {"America/Santiago", ~D[2026-09-06], ~U[2026-09-06 04:30:00Z], :inside}
      ]

      for {tz, day, starts_at, expected} <- cases do
        {:ok, event} =
          Events.create_event(scope, alice.uuid, %{
            "title" => "#{tz} #{DateTime.to_iso8601(starts_at)}",
            "starts_at" => DateTime.to_iso8601(starts_at),
            "ends_at" => DateTime.to_iso8601(DateTime.add(starts_at, 15, :minute))
          })

        {:ok, on_day} =
          Events.list_events(scope, alice.uuid, day, Date.add(day, 1), viewer_tz: tz)

        {:ok, day_before} =
          Events.list_events(scope, alice.uuid, Date.add(day, -1), day, viewer_tz: tz)

        assert event.uuid in Enum.map(on_day, & &1.uuid) == (expected == :inside),
               "#{tz} #{starts_at} on #{day}"

        assert event.uuid in Enum.map(day_before, & &1.uuid) == (expected == :day_before),
               "#{tz} #{starts_at} on #{Date.add(day, -1)}"
      end
    end

    test "an unresolvable viewer zone reads the window as UTC", %{alice: alice} do
      scope = scope_for(alice, ["calendar"])

      {:ok, event} =
        Events.create_event(scope, alice.uuid, %{
          "title" => "Late in UTC",
          "starts_at" => "2026-07-31T23:30:00Z",
          "ends_at" => "2026-07-31T23:45:00Z"
        })

      for tz <- ["nonsense", "", nil] do
        {:ok, july} =
          Events.list_events(scope, alice.uuid, ~D[2026-07-01], ~D[2026-08-01], viewer_tz: tz)

        assert event.uuid in Enum.map(july, & &1.uuid), inspect(tz)

        {:ok, august} =
          Events.list_events(scope, alice.uuid, ~D[2026-08-01], ~D[2026-09-01], viewer_tz: tz)

        refute event.uuid in Enum.map(august, & &1.uuid), inspect(tz)
      end
    end

    test "all-day events overlap the window by dates", %{alice: alice} do
      scope = scope_for(alice, ["calendar"])

      {:ok, event} =
        Events.create_event(scope, alice.uuid, %{
          "title" => "Vacation",
          "all_day" => "true",
          "starts_on" => "2026-06-28",
          "ends_on" => "2026-07-03"
        })

      # spans into the July window even though it starts in June
      {:ok, events} = Events.list_events(scope, alice.uuid, ~D[2026-07-01], ~D[2026-08-01])
      assert Enum.map(events, & &1.uuid) == [event.uuid]
    end

    test "someone else's calendar needs view_others (edit_others implies it)",
         %{alice: alice, bob: bob} do
      {:ok, _} = Events.create_event(scope_for(bob, ["calendar"]), bob.uuid, timed_attrs())

      base_only = scope_for(alice, ["calendar"])
      viewer = scope_for(alice, ["calendar", "calendar.view_others"])
      editor = scope_for(alice, ["calendar", "calendar.edit_others"])

      assert {:error, :unauthorized} =
               Events.list_events(base_only, bob.uuid, ~D[2026-07-01], ~D[2026-08-01])

      assert {:ok, [_]} = Events.list_events(viewer, bob.uuid, ~D[2026-07-01], ~D[2026-08-01])
      assert {:ok, [_]} = Events.list_events(editor, bob.uuid, ~D[2026-07-01], ~D[2026-08-01])
    end
  end

  describe "get_event/2" do
    test "authorizes against the event's owner", %{alice: alice, bob: bob} do
      {:ok, event} =
        Events.create_event(scope_for(bob, ["calendar"]), bob.uuid, timed_attrs())

      assert {:error, :unauthorized} =
               Events.get_event(scope_for(alice, ["calendar"]), event.uuid)

      assert {:ok, _} =
               Events.get_event(
                 scope_for(alice, ["calendar", "calendar.view_others"]),
                 event.uuid
               )
    end

    test "unknown uuid is :not_found", %{alice: alice} do
      scope = scope_for(alice, ["calendar"])
      assert {:error, :not_found} = Events.get_event(scope, Ecto.UUID.generate())
    end
  end

  describe "list_all_events/3 (the Everyone view)" do
    test "returns every calendar's events for cross-calendar readers",
         %{alice: alice, bob: bob} do
      {:ok, a} = Events.create_event(scope_for(alice, ["calendar"]), alice.uuid, timed_attrs())

      {:ok, b} =
        Events.create_event(
          scope_for(bob, ["calendar"]),
          bob.uuid,
          timed_attrs(%{"title" => "Bob thing"})
        )

      viewer = scope_for(alice, ["calendar", "calendar.view_others"])

      {:ok, events} = Events.list_all_events(viewer, ~D[2026-07-01], ~D[2026-08-01])
      uuids = Enum.map(events, & &1.uuid)
      assert a.uuid in uuids
      assert b.uuid in uuids
    end

    test "unauthorized without a cross-calendar key", %{alice: alice} do
      base_only = scope_for(alice, ["calendar"])

      assert {:error, :unauthorized} =
               Events.list_all_events(base_only, ~D[2026-07-01], ~D[2026-08-01])
    end
  end

  describe "count_events_by_owner/1" do
    test "gated on cross-calendar read access", %{alice: alice, bob: bob} do
      {:ok, _} = Events.create_event(scope_for(bob, ["calendar"]), bob.uuid, timed_attrs())

      assert {:error, :unauthorized} =
               Events.count_events_by_owner(scope_for(alice, ["calendar"]))

      assert {:ok, counts} =
               Events.count_events_by_owner(
                 scope_for(alice, ["calendar", "calendar.view_others"])
               )

      assert counts[bob.uuid] == 1
    end
  end
end
