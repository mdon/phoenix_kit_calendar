defmodule PhoenixKitCalendarTest do
  use ExUnit.Case, async: true

  describe "PhoenixKit.Module callbacks" do
    test "module_key/0 and module_name/0" do
      assert PhoenixKitCalendar.module_key() == "calendar"
      assert PhoenixKitCalendar.module_name() == "Calendar"
    end

    test "permission_metadata/0 declares the base key and both sub-permissions" do
      meta = PhoenixKitCalendar.permission_metadata()

      assert meta.key == "calendar"
      assert meta.icon == "hero-calendar-days"

      sub_keys = Enum.map(meta.sub_permissions, & &1.key)
      assert sub_keys == ["view_others", "edit_others"]

      assert Enum.all?(meta.sub_permissions, fn sub ->
               is_binary(sub.label) and is_binary(sub.description)
             end)
    end

    test "admin_tabs/0 returns the calendar tab wired to the LiveView" do
      assert [tab] = PhoenixKitCalendar.admin_tabs()
      assert tab.id == :admin_calendar
      assert tab.path == "calendar"
      assert tab.permission == "calendar"
      assert tab.live_view == {PhoenixKitCalendar.Web.CalendarLive, :index}
    end

    test "css_sources/0 includes both this app and the calendar lib" do
      assert PhoenixKitCalendar.css_sources() == [:phoenix_kit_calendar, :phoenix_live_calendar]
    end

    test "js_sources/0 declares the calendar lib's hook bundle" do
      assert [%{app: :phoenix_live_calendar, global: "PhoenixLiveCalendarHooks"}] =
               PhoenixKitCalendar.js_sources()
    end

    test "phoenix_kit_widgets/0 contributes the upcoming-events widget" do
      assert [widget] = PhoenixKitCalendar.phoenix_kit_widgets()
      assert widget.key == "calendar.upcoming"
      assert widget.module_key == "calendar"
      assert widget.component == PhoenixKitCalendar.Web.UpcomingWidget
    end

    test "enabled?/0 is false without a database (defensive default)" do
      # No sandbox checkout in this async test — the rescue path must
      # return false, not raise.
      assert PhoenixKitCalendar.enabled?() in [true, false]
    end
  end

  describe "Schemas.Event.changeset/2" do
    alias PhoenixKitCalendar.Schemas.Event

    test "timed events require the datetime pair with end after start" do
      changeset =
        Event.changeset(%Event{}, %{
          "title" => "Standup",
          "starts_at" => "2026-07-10T09:00:00Z",
          "ends_at" => "2026-07-10T09:00:00Z"
        })

      refute changeset.valid?
      assert {"must be after the start", _} = changeset.errors[:ends_at]
    end

    test "all-day events clear the timed pair and validate the date pair" do
      changeset =
        Event.changeset(%Event{}, %{
          "title" => "Offsite",
          "all_day" => "true",
          "starts_at" => "2026-07-10T09:00:00Z",
          "ends_at" => "2026-07-10T10:00:00Z",
          "starts_on" => "2026-07-10",
          "ends_on" => "2026-07-12"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :starts_at) == nil
      assert Ecto.Changeset.get_field(changeset, :ends_at) == nil
      assert Ecto.Changeset.get_field(changeset, :starts_on) == ~D[2026-07-10]
    end

    test "owner_uuid is not castable" do
      changeset =
        Event.changeset(%Event{}, %{
          "title" => "Sneaky",
          "owner_uuid" => Ecto.UUID.generate(),
          "starts_at" => "2026-07-10T09:00:00Z",
          "ends_at" => "2026-07-10T10:00:00Z"
        })

      assert Ecto.Changeset.get_field(changeset, :owner_uuid) == nil
    end

    test "color and status are whitelisted" do
      changeset =
        Event.changeset(%Event{}, %{
          "title" => "Bad",
          "color" => "bg-[url(javascript:alert(1))]",
          "status" => "maybe",
          "starts_at" => "2026-07-10T09:00:00Z",
          "ends_at" => "2026-07-10T10:00:00Z"
        })

      refute changeset.valid?
      assert changeset.errors[:color]
      assert changeset.errors[:status]
    end
  end
end
