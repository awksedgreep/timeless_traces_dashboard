defmodule TimelessTracesDashboard.HistoricalSourceTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveDashboard.PageBuilder
  alias Phoenix.LiveView.Socket
  alias TimelessTracesDashboard.Page

  setup do
    previous = Application.get_env(:timeless_traces_dashboard, :historical_source)

    on_exit(fn ->
      if previous do
        Application.put_env(:timeless_traces_dashboard, :historical_source, previous)
      else
        Application.delete_env(:timeless_traces_dashboard, :historical_source)
      end
    end)
  end

  test "real dashboard search and trace-detail callbacks use the configured historical source" do
    span = rich_span()

    Application.put_env(
      :timeless_traces_dashboard,
      :historical_source,
      {TimelessTracesDashboard.HistoricalSourceFixture, span: span, notify: self()}
    )

    socket = mounted_socket()

    search_params = %{
      "nav" => "search",
      "name" => "contract",
      "service" => "contract-svc",
      "kind" => "server",
      "status" => "error",
      "since" => "1700000000",
      "until" => "1700000001",
      "p" => "1",
      "per_page" => "25"
    }

    assert {:noreply, searched} = Page.handle_params(search_params, "", socket)
    assert searched.assigns.entries == [span]
    assert searched.assigns.has_more == false

    assert_receive {:historical_query, filters}
    assert filters[:name] == "contract"
    assert filters[:service] == "contract-svc"
    assert filters[:since] == 1_700_000_000_000_000_000
    assert filters[:until] == 1_700_000_001_000_000_000

    trace_params = %{"nav" => "traces", "trace_id" => span.trace_id}
    assert {:noreply, detailed} = Page.handle_params(trace_params, "", searched)
    assert detailed.assigns.trace_spans == [span]
    assert detailed.assigns.trace_id == span.trace_id
    assert_receive {:historical_trace, trace_id}
    assert trace_id == span.trace_id
  end

  test "stats use the same source and Rust mode rejects live tail without fallback" do
    Application.put_env(
      :timeless_traces_dashboard,
      :historical_source,
      {TimelessTracesDashboard.HistoricalSource.DataPlane,
       client: TimelessTracesDashboard.DataPlaneSourceFixture}
    )

    assert {:ok, %{total_entries: 3, storage_mode: :libsql}} =
             TimelessTracesDashboard.HistoricalSource.stats()

    assert {:error, {:unsupported_capability, :traces_live_tail}} =
             TimelessTracesDashboard.HistoricalSource.subscribe()

    assert {:error, {:unsupported_capability, :traces_live_tail}} =
             TimelessTracesDashboard.HistoricalSource.unsubscribe()
  end

  test "selected data-plane source fails closed without a configured client" do
    Application.put_env(
      :timeless_traces_dashboard,
      :historical_source,
      TimelessTracesDashboard.HistoricalSource.DataPlane
    )

    assert {:error, :missing_data_plane_client} =
             TimelessTracesDashboard.HistoricalSource.query([])
  end

  defp mounted_socket do
    page = %PageBuilder{params: %{}, route: :traces, node: nil}
    socket = %Socket{assigns: %{__changed__: %{}, page: page}}
    assert {:ok, socket} = Page.mount(%{}, %{}, socket)
    socket
  end

  defp rich_span do
    %TimelessTraces.Span{
      trace_id: "00112233445566778899aabbccddeeff",
      span_id: "0102030405060708",
      name: "GET /contract",
      kind: :server,
      start_time: 1_700_000_000_000_000_000,
      end_time: 1_700_000_000_120_000_000,
      duration_ns: 120_000_000,
      status: :error,
      status_message: "contract failure",
      attributes: %{"retryable" => true},
      events: [%{"name" => "exception"}],
      resource: %{"service.name" => "contract-svc"},
      instrumentation_scope: %{"name" => "contract-lib"}
    }
  end
end

defmodule TimelessTracesDashboard.HistoricalSourceFixture do
  @behaviour TimelessTracesDashboard.HistoricalSource

  @impl true
  def query(filters, opts) do
    send(Keyword.fetch!(opts, :notify), {:historical_query, filters})
    span = Keyword.fetch!(opts, :span)
    {:ok, %TimelessTraces.Result{entries: [span], total: 1, limit: 25}}
  end

  @impl true
  def trace(trace_id, opts) do
    send(Keyword.fetch!(opts, :notify), {:historical_trace, trace_id})
    {:ok, [Keyword.fetch!(opts, :span)]}
  end

  @impl true
  def stats(_opts), do: {:ok, %{total_entries: 1}}

  @impl true
  def subscribe(_opts), do: :ok

  @impl true
  def unsubscribe(_opts), do: :ok
end

defmodule TimelessTracesDashboard.DataPlaneSourceFixture do
  def stats do
    {:ok, %{"total_spans" => 3, "bytes_on_disk" => 90, "compressed_blocks" => 1}}
  end
end
