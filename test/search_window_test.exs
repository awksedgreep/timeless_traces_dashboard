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

  alias TimelessTracesDashboard.{Components, Page}

  defp search(params), do: Page.search_query_options(params)

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

  test "malformed numeric and enum parameters use safe defaults" do
    filters =
      search(%{
        "p" => "not-an-integer",
        "per_page" => "25oops",
        "since" => "invalid",
        "until" => "also-invalid",
        "kind" => "not-a-kind",
        "status" => "not-a-status"
      })

    assert filters[:offset] == 0
    assert filters[:limit] == 25
    assert is_integer(filters[:since])
    refute Keyword.has_key?(filters, :until)
    refute Keyword.has_key?(filters, :kind)
    refute Keyword.has_key?(filters, :status)
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
