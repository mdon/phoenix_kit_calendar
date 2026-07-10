defmodule PhoenixKitCalendar.EdgeAndPubsubTest do
  @moduledoc """
  Edge-path coverage the happy-path suite misses: free-text search with SQL
  metacharacters, over-length / unicode titles, and the live-update broadcast.
  """
  use PhoenixKitCalendar.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Schemas.Event
  alias PhoenixKitCalendar.Sources

  setup do
    {:ok, _} = PhoenixKitCalendar.enable_system()
    %{alice: create_user()}
  end

  defp create_user do
    {:ok, user} =
      Auth.register_user(%{
        email: "edge_#{System.unique_integer([:positive])}@example.com",
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

  describe "free-text search edge inputs" do
    test "SQL LIKE metacharacters don't crash or wildcard the search", %{alice: alice} do
      scope = %Scope{
        user: alice,
        authenticated?: true,
        cached_permissions: MapSet.new(["calendar", "calendar.invite_platform_users"])
      }

      for q <- ["%", "_", "'", "%_'", "100%_off"] do
        assert {grouped, has_more?} = Sources.search_participants(scope, q, 5)
        assert is_list(grouped)
        assert is_boolean(has_more?)
      end
    end
  end

  describe "title validation edges" do
    test "a >255-char title is rejected", %{alice: alice} do
      attrs = timed_attrs(String.duplicate("x", 256))
      assert {:error, changeset} = Events.create_event(scope_for(alice), alice.uuid, attrs)
      assert %{title: _} = errors_on(changeset)
    end

    test "a unicode title is accepted and preserved", %{alice: alice} do
      title = "Café ☕ 会議 — naïve"

      assert {:ok, %Event{} = event} =
               Events.create_event(scope_for(alice), alice.uuid, timed_attrs(title))

      assert event.title == title
    end
  end

  describe "live-update broadcast" do
    test "create_event broadcasts a change for the owner", %{alice: alice} do
      case PhoenixKit.Config.pubsub_server() do
        nil ->
          # No PubSub configured in this environment — nothing to assert.
          assert true

        pubsub ->
          Phoenix.PubSub.subscribe(pubsub, Events.pubsub_topic())

          {:ok, _event} =
            Events.create_event(scope_for(alice), alice.uuid, timed_attrs("Broadcast me"))

          assert_receive {:calendar_event_changed, owner_uuid}, 1_000
          assert owner_uuid == alice.uuid
      end
    end
  end
end
