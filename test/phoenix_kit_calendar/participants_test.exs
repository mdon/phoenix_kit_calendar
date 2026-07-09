defmodule PhoenixKitCalendar.ParticipantsTest do
  @moduledoc """
  Participants + live visibility resolution.

  Deliberately seeds the PHYSICAL staff/CRM/locations tables with
  schemaless inserts — those modules' code is NOT loaded in this suite,
  which is exactly the point: participant visibility and location
  snapshots must work from the tables alone (they exist in every install
  via core migrations).
  """
  use PhoenixKitCalendar.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Participants
  alias PhoenixKitCalendar.Sources

  setup do
    {:ok, _} = PhoenixKitCalendar.enable_system()

    _owner = create_user()
    alice = create_user()
    bob = create_user()

    {:ok, event} =
      Events.create_event(scope_for(alice, ["calendar"]), alice.uuid, %{
        "title" => "Kickoff",
        "starts_at" => "2026-07-10T09:00:00Z",
        "ends_at" => "2026-07-10T10:00:00Z"
      })

    %{alice: alice, bob: bob, event: event}
  end

  defp create_user do
    {:ok, user} =
      Auth.register_user(%{
        email: "part_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp scope_for(user, perms) do
    %Scope{
      user: user,
      authenticated?: true,
      cached_roles: ["Employee"],
      cached_permissions: MapSet.new(perms)
    }
  end

  defp editor(user), do: scope_for(user, ["calendar", "calendar.invite_platform_users"])

  defp seed(table, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    uuid = Ecto.UUID.generate()

    attrs =
      Map.merge(%{uuid: dump_uuid(uuid), inserted_at: now, updated_at: now}, attrs)

    {1, _} = Repo.insert_all(table, [attrs])
    uuid
  end

  defp dump_uuid(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    bin
  end

  defp user_entry(user),
    do: %{kind: "user", target_uuid: user.uuid, display_name: user.email}

  defp week_of(event_date \\ ~D[2026-07-10]),
    do: {Date.add(event_date, -7), Date.add(event_date, 7)}

  defp visible_titles(viewer) do
    {from, until} = week_of()
    {:ok, events} = Events.list_events(scope_for(viewer, ["calendar"]), viewer.uuid, from, until)
    Enum.map(events, & &1.title)
  end

  describe "replace_participants/3 authorization and kinds" do
    test "requires event edit access", %{bob: bob, event: event} do
      viewer = scope_for(bob, ["calendar", "calendar.view_others"])

      assert {:error, :unauthorized} =
               Participants.replace_participants(viewer, event, [user_entry(bob)])
    end

    test "adding a user kind requires invite_platform_users", %{
      alice: alice,
      bob: bob,
      event: event
    } do
      no_invite = scope_for(alice, ["calendar"])

      assert {:error, :unauthorized} =
               Participants.replace_participants(no_invite, event, [user_entry(bob)])

      assert {:ok, [p]} =
               Participants.replace_participants(editor(alice), event, [user_entry(bob)])

      assert p.kind == "user"
      assert p.added_by_uuid == alice.uuid
    end

    test "free text needs no invite permission", %{alice: alice, event: event} do
      plain = scope_for(alice, ["calendar"])

      assert {:ok, [p]} =
               Participants.replace_participants(plain, event, [
                 %{kind: "free_text", target_uuid: nil, display_name: "External Guest"}
               ])

      assert p.kind == "free_text"
    end

    test "removal does not require the kind's invite permission", %{
      alice: alice,
      bob: bob,
      event: event
    } do
      {:ok, _} = Participants.replace_participants(editor(alice), event, [user_entry(bob)])

      # alice lost the invite permission but can still remove
      plain = scope_for(alice, ["calendar"])
      assert {:ok, []} = Participants.replace_participants(plain, event, [])
    end

    test "diff keeps unchanged rows", %{alice: alice, bob: bob, event: event} do
      {:ok, [kept]} = Participants.replace_participants(editor(alice), event, [user_entry(bob)])

      {:ok, participants} =
        Participants.replace_participants(editor(alice), event, [
          user_entry(bob),
          %{kind: "free_text", target_uuid: nil, display_name: "Guest"}
        ])

      assert Enum.any?(participants, &(&1.uuid == kept.uuid))
      assert length(participants) == 2
    end
  end

  describe "live visibility" do
    test "a user participant sees the event on their own calendar", %{
      alice: alice,
      bob: bob,
      event: event
    } do
      refute "Kickoff" in visible_titles(bob)

      {:ok, _} = Participants.replace_participants(editor(alice), event, [user_entry(bob)])
      assert "Kickoff" in visible_titles(bob)

      # removal revokes immediately
      {:ok, _} = Participants.replace_participants(editor(alice), event, [])
      refute "Kickoff" in visible_titles(bob)
    end

    test "a staff participant resolves through the person's user link", %{
      alice: alice,
      bob: bob,
      event: event
    } do
      person_uuid = seed("phoenix_kit_staff_people", %{user_uuid: dump_uuid(bob.uuid)})

      {:ok, _} =
        Participants.replace_participants(
          scope_for(alice, ["calendar", "calendar.invite_staff"]),
          event,
          [%{kind: "staff_person", target_uuid: person_uuid, display_name: "Bob (staff)"}]
        )

      assert "Kickoff" in visible_titles(bob)
    end

    test "a company participant means CURRENT members — live, not snapshot", %{
      alice: alice,
      bob: bob,
      event: event
    } do
      company_uuid = seed("phoenix_kit_crm_companies", %{name: "Acme"})
      contact_uuid = seed("phoenix_kit_crm_contacts", %{user_uuid: dump_uuid(bob.uuid)})

      {:ok, _} =
        Participants.replace_participants(
          scope_for(alice, ["calendar", "calendar.invite_crm"]),
          event,
          [%{kind: "crm_company", target_uuid: company_uuid, display_name: "Acme"}]
        )

      # bob is not a member yet — no visibility
      refute "Kickoff" in visible_titles(bob)

      # joining the company grants visibility WITHOUT touching the event
      membership_uuid =
        seed("phoenix_kit_crm_company_memberships", %{
          contact_uuid: dump_uuid(contact_uuid),
          company_uuid: dump_uuid(company_uuid)
        })

      assert "Kickoff" in visible_titles(bob)

      # leaving the company revokes it just as automatically
      Repo.delete_all(
        from(m in "phoenix_kit_crm_company_memberships",
          where: m.uuid == type(^membership_uuid, Ecto.UUID)
        )
      )

      refute "Kickoff" in visible_titles(bob)
    end

    test "free-text participants grant no visibility", %{alice: alice, bob: bob, event: event} do
      {:ok, _} =
        Participants.replace_participants(scope_for(alice, ["calendar"]), event, [
          %{kind: "free_text", target_uuid: nil, display_name: bob.email}
        ])

      refute "Kickoff" in visible_titles(bob)
    end

    test "a participant may open the single event but not the owner's calendar", %{
      alice: alice,
      bob: bob,
      event: event
    } do
      {:ok, _} = Participants.replace_participants(editor(alice), event, [user_entry(bob)])

      bob_scope = scope_for(bob, ["calendar"])
      assert {:ok, _} = Events.get_event(bob_scope, event.uuid)

      # the rest of alice's calendar stays closed
      {from, until} = week_of()
      assert {:error, :unauthorized} = Events.list_events(bob_scope, alice.uuid, from, until)
    end
  end

  describe "notifications" do
    test "newly added resolvable participants get an activity with target_uuid", %{
      alice: alice,
      bob: bob,
      event: event
    } do
      {:ok, _} = Participants.replace_participants(editor(alice), event, [user_entry(bob)])

      activities =
        from(a in "phoenix_kit_activities",
          where: a.action == "calendar_event.participant_added",
          select: %{target_uuid: type(a.target_uuid, Ecto.UUID)}
        )
        |> Repo.all()

      assert Enum.any?(activities, &(&1.target_uuid == bob.uuid))

      # re-saving the same set adds nothing new
      {:ok, _} = Participants.replace_participants(editor(alice), event, [user_entry(bob)])

      count =
        from(a in "phoenix_kit_activities",
          where: a.action == "calendar_event.participant_added",
          select: count()
        )
        |> Repo.one()

      assert count == 1
    end
  end

  describe "sources" do
    test "participant sources are gated by invite permissions", %{alice: alice} do
      assert Sources.available_participant_sources(scope_for(alice, ["calendar"])) == []

      assert Sources.available_participant_sources(editor(alice)) == [:users]

      # staff/crm sources stay hidden — those modules are not loaded in
      # this suite even though their tables exist
      full =
        scope_for(alice, [
          "calendar",
          "calendar.invite_platform_users",
          "calendar.invite_staff",
          "calendar.invite_crm"
        ])

      assert Sources.available_participant_sources(full) == [:users]
    end

    test "user search needs two characters and returns name-only entries", %{
      alice: alice,
      bob: bob
    } do
      scope = editor(alice)

      assert Sources.search_participants(scope, "x") == []

      results = Sources.search_participants(scope, bob.email)
      assert [{:users, [entry]}] = results
      assert entry.kind == "user"
      assert entry.target_uuid == bob.uuid
      assert Map.keys(entry) |> Enum.sort() == [:display_name, :kind, :target_uuid]
    end

    test "locations list is empty while the locations module is unavailable" do
      seed("phoenix_kit_locations", %{name: "HQ"})
      assert Sources.list_locations() == []
    end
  end

  describe "location snapshot" do
    test "a linked location's name is snapshotted into the location string", %{alice: alice} do
      location_uuid = seed("phoenix_kit_locations", %{name: "Meeting Room 4"})

      {:ok, event} =
        Events.create_event(scope_for(alice, ["calendar"]), alice.uuid, %{
          "title" => "On site",
          "location_uuid" => location_uuid,
          "starts_at" => "2026-07-11T09:00:00Z",
          "ends_at" => "2026-07-11T10:00:00Z"
        })

      assert event.location == "Meeting Room 4"
      assert event.location_uuid == location_uuid
    end

    test "an unknown location_uuid is dropped, free text kept", %{alice: alice} do
      {:ok, event} =
        Events.create_event(scope_for(alice, ["calendar"]), alice.uuid, %{
          "title" => "Off site",
          "location" => "Cafe corner",
          "location_uuid" => Ecto.UUID.generate(),
          "starts_at" => "2026-07-11T09:00:00Z",
          "ends_at" => "2026-07-11T10:00:00Z"
        })

      assert event.location == "Cafe corner"
      assert event.location_uuid == nil
    end
  end
end
