defmodule TimelessTracesDashboard.SearchWindowTest do
  @moduledoc """
  The trace search form bounds queries by time, and paging keeps the bound.

  `start_ts` pushes into the storage engine, so a range makes paging cheap; an
  unbounded search walks the whole store. This mirrors the control in
  timeless_logs_dashboard so the two plugins behave the same way — same
  parameter name, same options, same labels. The unit differs because the
  stores differ: traces take seconds here, logs microseconds.

  The pager is tested separately from the page because it builds its own links
  and originally omitted the range, exactly as the logs pager did.
  """

  use ExUnit.Case, async: false

  alias Phoenix.LiveDashboard.PageBuilder
  alias TimelessTracesDashboard.{Components, Page}

  defmodule Recorder do
    @moduledoc false
    @behaviour TimelessTracesDashboard.HistoricalSource

    @impl true
    def query(filters, _opts) do
      send(self(), {:query_filters, filters})
      {:ok, %{entries: [], total: 0, has_more: false}}
    end

    @impl true
    def trace(_id, _opts), do: {:ok, []}

    @impl true
    def stats(_opts), do: {:ok, %{}}

    @impl true
    def subscribe(_opts), do: :ok

    @impl true
    def unsubscribe(_opts), do: :ok
  end

  setup do
    previous = Application.get_env(:timeless_traces_dashboard, :historical_source)
    Application.put_env(:timeless_traces_dashboard, :historical_source, Recorder)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:timeless_traces_dashboard, :historical_source, previous),
        else: Application.delete_env(:timeless_traces_dashboard, :historical_source)
    end)

    :ok
  end

  defp search(params) do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        page: %PageBuilder{params: params, route: :traces, node: nil},
        per_page: 25
      }
    }

    Page.handle_params(Map.put(params, "nav", "search"), "/", socket)

    receive do
      {:query_filters, filters} -> filters
    after
      0 -> flunk("the page never queried the historical source")
    end
  end

  test "a search with no explicit range is bounded to the last 24 hours" do
    filters = search(%{"name" => "GET /"})

    assert since = Keyword.get(filters, :since)

    # The page converts seconds to nanoseconds before it reaches the engine.
    day_ago_ns = (DateTime.utc_now() |> DateTime.to_unix()) * 1_000_000_000 - 86_400_000_000_000

    assert_in_delta since, day_ago_ns, 60_000_000_000
  end

  test "a narrower range is respected" do
    filters = search(%{"window" => "1h"})

    assert since = Keyword.get(filters, :since)
    hour_ago_ns = (DateTime.utc_now() |> DateTime.to_unix()) * 1_000_000_000 - 3_600_000_000_000

    assert_in_delta since, hour_ago_ns, 60_000_000_000
  end

  test "All time removes the bound entirely" do
    filters = search(%{"window" => "all"})

    refute Keyword.has_key?(filters, :since)
  end

  test "an explicit since wins over the range" do
    filters = search(%{"since" => "1700000000"})

    assert Keyword.get(filters, :since) == 1_700_000_000 * 1_000_000_000
  end

  test "an unknown range falls back to the default rather than dropping the bound" do
    filters = search(%{"window" => "nonsense"})

    assert since = Keyword.get(filters, :since)
    day_ago_ns = (DateTime.utc_now() |> DateTime.to_unix()) * 1_000_000_000 - 86_400_000_000_000

    assert_in_delta since, day_ago_ns, 60_000_000_000
  end

  test "page two keeps the bound and shifts the offset" do
    filters = search(%{"p" => "2", "per_page" => "25"})

    assert Keyword.get(filters, :offset) == 25
    assert Keyword.get(filters, :limit) == 25
    assert Keyword.has_key?(filters, :since)
  end

  describe "the pager carries the range" do
    test "next/prev params keep the selected range" do
      assert %{window: "all", p: "3"} =
               Components.page_params(3, "GET /", "api", "", "", "all", 25)
    end

    test "a narrower range also survives paging" do
      assert %{window: "7d"} = Components.page_params(2, "", "", "server", "error", "7d", 50)
    end

    test "the rest of the search is preserved alongside it" do
      params = Components.page_params(2, "GET /", "api", "server", "error", "7d", 50)

      assert params.name == "GET /"
      assert params.service == "api"
      assert params.kind == "server"
      assert params.status == "error"
      assert params.per_page == "50"
      assert params.nav == "search"
    end
  end

  test "the ranges match the logs plugin" do
    # The two dashboards are separate packages with no shared dependency, so
    # uniformity cannot be asserted by comparing them directly. Pinning the
    # list in both means whichever one drifts fails its own suite.
    assert Page.window_options() == [
             {"1h", "Last hour"},
             {"24h", "Last 24 hours"},
             {"7d", "Last 7 days"},
             {"30d", "Last 30 days"},
             {"all", "All time"}
           ]
  end
end
