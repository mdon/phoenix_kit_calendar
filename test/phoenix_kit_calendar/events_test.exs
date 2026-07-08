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
