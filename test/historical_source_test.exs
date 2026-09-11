defmodule TimelessTracesDashboard.HistoricalSourceTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveDashboard.PageBuilder
  alias Phoenix.LiveView.Lifecycle
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
    assert searched.assigns.search_loading
    assert searched.assigns.entries == []

    assert_receive {:historical_query, filters}
    searched = await_async(searched, :search)

    assert searched.assigns.entries == [span]
    assert searched.assigns.has_more == false

    assert filters[:name] == "contract"
    assert filters[:service] == "contract-svc"
    assert filters[:since] == 1_700_000_000_000_000_000
    assert filters[:until] == 1_700_000_001_000_000_000

    trace_params = %{"nav" => "traces", "trace_id" => span.trace_id}
    assert {:noreply, detailed} = Page.handle_params(trace_params, "", searched)
    assert detailed.assigns.trace_loading

    assert_receive {:historical_trace, trace_id}
    detailed = await_async(detailed, :trace)

    assert detailed.assigns.trace_spans == [span]
    assert detailed.assigns.trace_id == span.trace_id
    assert trace_id == span.trace_id

    assert {:noreply, expanded} =
             Page.handle_event("toggle_span_detail", %{"span_id" => span.span_id}, detailed)

    assert MapSet.member?(expanded.assigns.expanded_spans, span.span_id)
    assert Map.has_key?(expanded.assigns.expanded_span_details, span.span_id)

    assert {:noreply, next_trace} =
             Page.handle_params(
               %{"nav" => "traces", "trace_id" => String.duplicate("f", 32)},
               "",
               expanded
             )

    assert next_trace.assigns.expanded_spans == MapSet.new()
    assert next_trace.assigns.expanded_span_details == %{}
  end

  test "leaving live tail unsubscribes and ignores later span messages" do
    span = rich_span()

    Application.put_env(
      :timeless_traces_dashboard,
      :historical_source,
      {TimelessTracesDashboard.HistoricalSourceFixture, span: span, notify: self()}
    )

    socket = mounted_socket()
    assert {:noreply, tail} = Page.handle_params(%{"nav" => "tail"}, "", socket)
    assert tail.assigns.subscribed
    assert_receive :historical_subscribe

    assert {:noreply, streamed} = Page.handle_info({:timeless_traces, :span, span}, tail)
    assert streamed.assigns.tail_count == 1
    refute Map.has_key?(streamed.assigns, :tail_entries)

    assert {:noreply, searched} =
             Page.handle_params(%{"nav" => "search", "window" => "all"}, "", streamed)

    refute searched.assigns.subscribed
    assert_receive :historical_unsubscribe

    assert {:noreply, unchanged} =
             Page.handle_info({:timeless_traces, :span, span}, searched)

    assert unchanged.assigns.tail_count == 1
  end

  test "stats use the same source and Rust mode rejects live tail without fallback" do
    Application.put_env(
      :timeless_traces_dashboard,
      :historical_source,
      {TimelessTracesDashboard.HistoricalSource.DataPlane,
       client: TimelessTracesDashboard.DataPlaneSourceFixture}
    )

    assert {:ok,
            %{
              total_entries: 3,
              total_bytes: 90,
              raw_ingested_bytes: 450,
              storage_mode: :libsql
            }} =
             TimelessTracesDashboard.HistoricalSource.stats()

    assert {:error, {:unsupported_capability, :traces_live_tail}} =
             TimelessTracesDashboard.HistoricalSource.subscribe()

    assert {:error, {:unsupported_capability, :traces_live_tail}} =
             TimelessTracesDashboard.HistoricalSource.unsubscribe()
  end

  describe "local source honours the subscribe contract" do
    # TimelessTraces.subscribe/1 delegates to Registry.register/3, which answers
    # {:ok, pid}. Leaking that shape broke live tail: the dashboard matches the
    # declared :ok | {:error, term()} contract and crashed with a
    # CaseClauseError on the success path, so the LiveView died on mount and the
    # page hung. The logs dashboard had the identical defect.
    setup do
      Application.put_env(
        :timeless_traces_dashboard,
        :historical_source,
        TimelessTracesDashboard.HistoricalSource.Local
      )

      {:ok, _} = Application.ensure_all_started(:timeless_traces)
      on_exit(fn -> TimelessTraces.unsubscribe() end)
      :ok
    end

    test "subscribe returns :ok, not Registry's {:ok, pid}" do
      assert :ok = TimelessTracesDashboard.HistoricalSource.subscribe()
    end

    test "subscribing twice is still :ok" do
      assert :ok = TimelessTracesDashboard.HistoricalSource.subscribe()
      assert :ok = TimelessTracesDashboard.HistoricalSource.subscribe()
    end

    test "unsubscribe returns :ok" do
      assert :ok = TimelessTracesDashboard.HistoricalSource.subscribe()
      assert :ok = TimelessTracesDashboard.HistoricalSource.unsubscribe()
    end
  end

  test "pre-upgrade stats JSON without the raw counter normalizes it to 0" do
    Application.put_env(
      :timeless_traces_dashboard,
      :historical_source,
      {TimelessTracesDashboard.HistoricalSource.DataPlane,
       client: TimelessTracesDashboard.LegacyDataPlaneSourceFixture}
    )

    assert {:ok, %{total_bytes: 90, raw_ingested_bytes: 0}} =
             TimelessTracesDashboard.HistoricalSource.stats()
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

    socket = %Socket{
      assigns: %{__changed__: %{}, page: page},
      root_pid: self(),
      transport_pid: self(),
      private: %{live_temp: %{}, lifecycle: %Lifecycle{}}
    }

    assert {:ok, socket} = Page.mount(%{}, %{}, socket)
    socket
  end

  defp await_async(socket, key) do
    {ref, _pid} = Map.fetch!(socket.assigns.async_refs, key)
    assert_receive {:timeless_dashboard_async, ^key, ^ref, result}

    assert {:noreply, socket} =
             Page.handle_info({:timeless_dashboard_async, key, ref, result}, socket)

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
  def subscribe(opts) do
    notify(opts, :historical_subscribe)
    :ok
  end

  @impl true
  def unsubscribe(opts) do
    notify(opts, :historical_unsubscribe)
    :ok
  end

  defp notify(opts, message) do
    if pid = Keyword.get(opts, :notify), do: send(pid, message)
  end
end

defmodule TimelessTracesDashboard.DataPlaneSourceFixture do
  def stats do
    {:ok,
     %{
       "total_spans" => 3,
       "bytes_on_disk" => 90,
       "compressed_blocks" => 1,
       "raw_ingested_bytes_total" => 450
     }}
  end
end

defmodule TimelessTracesDashboard.LegacyDataPlaneSourceFixture do
  def stats do
    {:ok, %{"total_spans" => 3, "bytes_on_disk" => 90, "compressed_blocks" => 1}}
  end
end
