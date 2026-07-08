defmodule PhoenixKitCalendar.DataCase do
  @moduledoc """
  Test case for tests requiring database access.

  Uses PhoenixKitCalendar.Test.Repo with SQL Sandbox for isolation.
  Tests using this case are tagged `:integration` and will be
  automatically excluded when the database is unavailable.

  ## Usage

      defmodule MyModule.Integration.SomeTest do
        use PhoenixKitCalendar.DataCase, async: true

        test "creates a record" do
          # Repo is available, transactions are isolated
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitCalendar.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitCalendar.ActivityLogAssertions
      import PhoenixKitCalendar.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitCalendar.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end

  @doc """
  Translates changeset errors into a `%{field => [message]}` map. Used
  by tests that assert on changeset error messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
