defmodule TimelessTracesDashboard.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias TimelessTracesDashboard.Components

  # A stats map shaped like HistoricalSource.DataPlane.normalize_stats/1
  # output. The codec totals are deliberately present alongside the raw
  # counter so the tests prove which source the tile prefers.
  @stats %{
    total_entries: 1_000,
    total_bytes: 2_000,
    raw_blocks: 0,
    raw_bytes: 0,
    compressed_blocks: 4,
    compressed_bytes: 2_000,
    compression_raw_bytes_in: 3_000_000,
    compression_compressed_bytes_out: 1_000_000,
    raw_ingested_bytes: 0,
    compaction_count: 2,
    oldest_timestamp: nil,
    newest_timestamp: nil,
    storage_mode: :libsql
  }

  test "headline ratio is raw ingested bytes over stored data-block bytes" do
    stats = %{@stats | raw_ingested_bytes: 10_000}

    html = render_component(&Components.stats_tab/1, stats: stats)

    # 10_000 raw / 2_000 stored, not the 3.0x the codec totals would give.
    assert html =~ "5.0x (80.0% smaller)"
    refute html =~ "3.0x"
  end

  test "zero raw counter (older server or pre-upgrade database) falls back to codec totals" do
    html = render_component(&Components.stats_tab/1, stats: @stats)

    # 3_000_000 in / 1_000_000 out from the extension compression totals.
    assert html =~ "3.0x (66.7% smaller)"
  end

  test "no counters at all with uncompressed raw blocks shows pending" do
    stats = %{
      @stats
      | compression_raw_bytes_in: 0,
        compression_compressed_bytes_out: 0,
        raw_blocks: 3,
        compressed_blocks: 0
    }

    html = render_component(&Components.stats_tab/1, stats: stats)

    assert html =~ "pending"
  end

  test "span rows precompute service and timestamp display values" do
    span = span("child", "parent", 1_700_000_000_000_000_000)
    row = Components.prepare_span_row(span)

    assert row.span == span
    assert row.service == "contract-svc"
    assert row.timestamp == "2023-11-14 22:13:20"
  end

  test "trace presentation is built once with tree depth and duration" do
    child = span("child", "root", 120)
    root = span("root", nil, 100)
    trace = Components.prepare_trace([child, root])

    assert trace.count == 2
    assert trace.start == 100
    assert trace.duration == 30

    assert Enum.map(trace.rows, &{&1.span.span_id, &1.depth, &1.service}) == [
             {"root", 0, "contract-svc"},
             {"child", 1, "contract-svc"}
           ]
  end

  test "expanded detail values are sorted, formatted once, and bounded" do
    long_value = String.duplicate("x", 1_000)
    span = %{span("root", nil, 100) | attributes: %{"z" => [1, 2], "a" => long_value}}
    detail = Components.prepare_span_detail(span)

    assert Enum.map(detail.attributes, & &1.key) == ["a", "z"]
    assert [%{value: truncated}, %{value: "[1, 2]"}] = detail.attributes
    assert String.length(truncated) == 501
    assert String.ends_with?(truncated, "…")
  end

  test "prepared trace and tail rows render without presentation work in the template" do
    span = span("root", nil, 1_700_000_000_000_000_000)
    trace = Components.prepare_trace([span])
    details = %{span.span_id => Components.prepare_span_detail(span)}

    trace_html =
      render_component(&Components.trace_tab/1,
        trace: trace,
        trace_id_input: span.trace_id,
        trace_id: span.trace_id,
        expanded_spans: MapSet.new([span.span_id]),
        expanded_span_details: details
      )

    assert trace_html =~ "contract-svc"
    assert trace_html =~ span.span_id

    row = Components.prepare_span_row(span)

    tail_html =
      render_component(&Components.tail_tab/1,
        entries: [{"tail-row", row}],
        count: 1,
        subscribed: true
      )

    assert tail_html =~ ~s(id="tail-entries")
    assert tail_html =~ ~s(id="tail-row")
    assert tail_html =~ "Streaming... (1 spans)"
  end

  test "the trace tab renders before a trace is chosen and when none is found" do
    empty = Components.prepare_trace([])

    # The tab opens with no trace chosen: `nil && …` was nil, and `nil and …`
    # raised BadBooleanError, a 500 on every visit to the tab.
    unchosen =
      render_component(&Components.trace_tab/1,
        trace: empty,
        trace_id_input: "",
        trace_id: nil
      )

    assert unchosen =~ "Enter trace ID"
    refute unchosen =~ "No spans found for this trace."

    missing =
      render_component(&Components.trace_tab/1,
        trace: empty,
        trace_id_input: "ffffffffffffffffffffffffffffffff",
        trace_id: "ffffffffffffffffffffffffffffffff"
      )

    assert missing =~ "No spans found for this trace."

    loading =
      render_component(&Components.trace_tab/1,
        trace: empty,
        loading: true,
        trace_id_input: "ffffffffffffffffffffffffffffffff",
        trace_id: "ffffffffffffffffffffffffffffffff"
      )

    assert loading =~ "Loading trace..."
    refute loading =~ "No spans found for this trace."
  end

  defp span(span_id, parent_span_id, start_time) do
    %TimelessTraces.Span{
      trace_id: "00112233445566778899aabbccddeeff",
      span_id: span_id,
      parent_span_id: parent_span_id,
      name: span_id,
      kind: :server,
      start_time: start_time,
      end_time: start_time + 10,
      duration_ns: 10,
      status: :ok,
      attributes: %{},
      events: [],
      resource: %{"service.name" => "contract-svc"},
      instrumentation_scope: %{}
    }
  end
end
