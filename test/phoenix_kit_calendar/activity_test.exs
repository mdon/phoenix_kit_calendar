defmodule PhoenixKitCalendar.ActivityTest do
  @moduledoc """
  Pins the activity-log side effects of event mutations: every CRUD action
  logs with the acting user + the event uuid, and — the load-bearing privacy
  invariant — the event TITLE never enters the audit metadata.
  """
  use PhoenixKitCalendar.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitCalendar.Events

  setup do
    {:ok, _} = PhoenixKitCalendar.enable_system()
    %{alice: create_user()}
  end

  defp create_user do
    {:ok, user} =
      Auth.register_user(%{
        email: "act_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp scope_for(user),
    do: %Scope{user: user, authenticated?: true, cached_permissions: MapSet.new(["calendar"])}

  defp timed_attrs(title) do
    %{
      "title" => title,
      "all_day" => "false",
      "starts_at" => ~U[2026-08-01 09:00:00Z],
      "ends_at" => ~U[2026-08-01 10:00:00Z]
    }
  end

  test "create logs calendar_event.created with actor + owner, and NO title", %{alice: alice} do
    scope = scope_for(alice)
    {:ok, event} = Events.create_event(scope, alice.uuid, timed_attrs("Secret 1:1"))

    assert_activity_logged("calendar_event.created",
      resource_uuid: event.uuid,
      actor_uuid: alice.uuid,
      metadata_has: %{"owner_uuid" => alice.uuid}
    )

    # PII invariant: a free-text title must never reach the audit metadata —
    # not this value, and not the "title" key at all (a regression could log a
    # different value).
    refute_activity_logged("calendar_event.created", metadata_has: %{"title" => "Secret 1:1"})

    created = Enum.find(list_activities(), &(&1.action == "calendar_event.created"))
    refute Map.has_key?(created.metadata, "title")
  end

  test "update logs calendar_event.updated with actor + resource", %{alice: alice} do
    scope = scope_for(alice)
    {:ok, event} = Events.create_event(scope, alice.uuid, timed_attrs("Before"))
    {:ok, _} = Events.update_event(scope, event, %{"title" => "After"})

    assert_activity_logged("calendar_event.updated",
      resource_uuid: event.uuid,
      actor_uuid: alice.uuid
    )
  end

  test "delete logs calendar_event.deleted with actor + resource", %{alice: alice} do
    scope = scope_for(alice)
    {:ok, event} = Events.create_event(scope, alice.uuid, timed_attrs("Doomed"))
    {:ok, _} = Events.delete_event(scope, event)

    assert_activity_logged("calendar_event.deleted",
      resource_uuid: event.uuid,
      actor_uuid: alice.uuid
    )
  end
end
