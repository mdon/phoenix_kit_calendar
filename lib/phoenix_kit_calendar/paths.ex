defmodule PhoenixKitCalendar.Paths do
  @moduledoc """
  Centralized path helpers for the Calendar module.

  All paths go through `PhoenixKit.Utils.Routes.path/1` for prefix/locale
  handling — never hardcode `"/admin/calendar"` in LiveViews.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/calendar"

  @doc "The calendar page (own calendar)."
  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  @doc """
  The calendar page opened on another user's calendar. Only meaningful for
  viewers holding `calendar.view_others`.
  """
  @spec for_user(String.t()) :: String.t()
  def for_user(user_uuid), do: Routes.path("#{@base}?user=#{user_uuid}")
end
