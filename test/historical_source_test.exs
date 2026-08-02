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
end
