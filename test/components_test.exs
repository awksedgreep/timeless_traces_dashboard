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
end
