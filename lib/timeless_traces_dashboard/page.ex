defmodule TimelessTracesDashboard.Page do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  import TimelessTracesDashboard.Components

  alias TimelessTracesDashboard.Components
  alias TimelessTracesDashboard.HistoricalSource

  @tail_cap 200
  @default_per_page 25

  @kinds %{
    "internal" => :internal,
    "server" => :server,
    "client" => :client,
    "producer" => :producer,
    "consumer" => :consumer
  }
  @statuses %{"ok" => :ok, "error" => :error, "unset" => :unset}

  # Mirrors timeless_logs_dashboard so the two plugins offer the same control.
  # Traces timestamps are seconds at this boundary (the page multiplies to
  # nanoseconds), where logs are microseconds — the vocabulary is shared, the
  # unit is each store's own.
  @windows %{"1h" => 3_600, "24h" => 86_400, "7d" => 604_800, "30d" => 2_592_000}
  @default_window "24h"

  @doc false
  def window_options,
    do: [
      {"1h", "Last hour"},
      {"24h", "Last 24 hours"},
      {"7d", "Last 7 days"},
      {"30d", "Last 30 days"},
      {"all", "All time"}
    ]

  @impl true
  def menu_link(_, _) do
    {:ok, "TimelessTraces"}
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        nav: "stats",
        windows: window_options(),
        entries: [],
        entry_rows: [],
        entry_count: 0,
        async_refs: %{},
        search_loading: false,
        total: 0,
        has_more: false,
        stats: nil,
        stats_loading: false,
        trace_spans: [],
        trace_view: Components.prepare_trace([]),
        trace_loading: false,
        trace_id_input: "",
        trace_id: nil,
        trace_lookup_us: nil,
        expanded_spans: MapSet.new(),
        expanded_span_details: %{},
        tail_count: 0,
        subscribed: false,
        tail_error: nil,
        name: "",
        service: "",
        kind: "",
        status: "",
        window: @default_window,
        per_page: @default_per_page,
        current_page: 1
      )
      |> stream_configure(:tail_entries,
        dom_id: fn row -> "tail-#{row.span.trace_id}-#{row.span.span_id}" end
      )
      |> stream(:tail_entries, [])

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_nav_bar
      id="span-tabs"
      page={@page}
      extra_params={["name", "service", "kind", "status", "window", "p", "per_page", "trace_id", "since", "until"]}
    >
      <:item name="stats" label="Stats"><span></span></:item>
      <:item name="search" label="Search"><span></span></:item>
      <:item name="traces" label="Traces"><span></span></:item>
      <:item name="tail" label="Live Tail"><span></span></:item>
    </.live_nav_bar>
    <.search_tab
      :if={@nav == "search"}
      entries={@entry_rows}
      entry_count={@entry_count}
      loading={@search_loading}
      total={@total}
      name={@name}
      service={@service}
      kind={@kind}
      status={@status}
      window={@window}
      windows={@windows}
      current_page={@current_page}
      per_page={@per_page}
      has_more={@has_more}
      page={@page}
      socket={@socket}
    />
    <.trace_tab
      :if={@nav == "traces"}
      trace={@trace_view}
      loading={@trace_loading}
      trace_id_input={@trace_id_input}
      trace_id={@trace_id}
      lookup_us={@trace_lookup_us}
      expanded_spans={@expanded_spans}
      expanded_span_details={@expanded_span_details}
      page={@page}
      socket={@socket}
    />
    <.stats_tab :if={@nav == "stats"} stats={@stats} loading={@stats_loading} />
    <.tail_tab
      :if={@nav == "tail"}
      entries={@streams.tail_entries}
      count={@tail_count}
      subscribed={@subscribed}
      error={@tail_error}
    />
    """
  end

  @impl true
  def handle_params(params, _uri, socket) do
    nav = resolve_nav(params)
    socket = socket |> leave_tail(nav) |> assign(:nav, nav)

    if Map.get(params, "nav") == nav do
      socket = apply_nav(nav, params, socket)
      {:noreply, socket}
    else
      to =
        live_dashboard_path(socket, socket.assigns.page, normalize_dashboard_params(params, nav))

      {:noreply, push_patch(socket, to: to)}
    end
  end

  defp apply_nav("search", params, socket) do
    name = Map.get(params, "name", "")
    service = Map.get(params, "service", "")
    {kind, _kind_filter} = enum_filter(Map.get(params, "kind", ""), @kinds)
    {status, _status_filter} = enum_filter(Map.get(params, "status", ""), @statuses)
    window = normalize_window(Map.get(params, "window", @default_window))
    per_page = parse_integer(Map.get(params, "per_page"), @default_per_page, 1, 100)
    current_page = parse_integer(Map.get(params, "p"), 1, 1, :infinity)

    query_opts = search_query_options(params)

    socket
    |> assign(
      search_loading: true,
      entry_rows: [],
      entry_count: 0,
      has_more: false,
      name: name,
      service: service,
      kind: kind,
      status: status,
      window: window,
      per_page: per_page,
      current_page: current_page
    )
    |> run_async(:search, fn -> HistoricalSource.query(query_opts) end)
  end

  defp apply_nav("traces", params, socket) do
    trace_id = Map.get(params, "trace_id", "")
    changed? = trace_id != (socket.assigns.trace_id || "")

    socket =
      if changed? do
        assign(socket,
          trace_spans: [],
          trace_view: Components.prepare_trace([]),
          expanded_spans: MapSet.new(),
          expanded_span_details: %{}
        )
      else
        socket
      end

    if trace_id != "" do
      socket
      |> assign(
        trace_loading: true,
        trace_id_input: trace_id,
        trace_id: trace_id,
        trace_lookup_us: nil
      )
      |> run_async(:trace, fn ->
        start = System.monotonic_time(:microsecond)
        result = HistoricalSource.trace(trace_id)
        {trace_id, result, System.monotonic_time(:microsecond) - start}
      end)
    else
      assign(socket,
        trace_spans: [],
        trace_view: Components.prepare_trace([]),
        trace_loading: false,
        trace_id_input: "",
        trace_id: nil,
        trace_lookup_us: nil
      )
    end
  end

  defp apply_nav("stats", _params, socket) do
    socket
    |> assign(:stats_loading, true)
    |> run_async(:stats, fn -> HistoricalSource.stats() end)
  end

  defp apply_nav("tail", _params, socket) do
    if connected?(socket) and not socket.assigns.subscribed do
      case HistoricalSource.subscribe() do
        :ok ->
          socket
          |> assign(subscribed: true, tail_count: 0, tail_error: nil)
          |> stream(:tail_entries, [], reset: true)

        {:error, reason} ->
          assign(socket, subscribed: false, tail_error: inspect(reason))
      end
    else
      socket
    end
  end

  defp apply_nav(_, _params, socket), do: socket

  # A trace search without a timestamp bound scans the whole store. start_ts
  # pushes down, so the default range keeps paging cheap; "All time" is still
  # available and the header names the active range, because a silent window
  # makes older data look missing.
  defp window_start("all"), do: ""

  defp window_start(window) do
    case Map.fetch(@windows, window) do
      {:ok, seconds} ->
        DateTime.utc_now()
        |> DateTime.add(-seconds, :second)
        |> DateTime.to_unix()
        |> Integer.to_string()

      :error ->
        window_start(@default_window)
    end
  end

  defp normalize_window(window) when is_map_key(@windows, window), do: window
  defp normalize_window("all"), do: "all"
  defp normalize_window(_window), do: @default_window

  defp resolve_nav(params) do
    case Map.get(params, "nav") do
      nav when nav in ["search", "traces", "stats", "tail"] ->
        nav

      _ ->
        "stats"
    end
  end

  defp build_filters(name, service, kind, status) do
    filters = []
    filters = if name != "", do: [{:name, name} | filters], else: filters
    filters = if service != "", do: [{:service, service} | filters], else: filters
    filters = if kind, do: [{:kind, kind} | filters], else: filters
    if status, do: [{:status, status} | filters], else: filters
  end

  defp enum_filter(value, allowed) do
    case Map.fetch(allowed, value) do
      {:ok, atom} -> {value, atom}
      :error -> {"", nil}
    end
  end

  defp add_time_filter(filters, key, value, fallback) do
    parsed =
      case parse_integer(value || "") do
        {:ok, _integer} = parsed -> parsed
        :error -> parse_integer(fallback)
      end

    case parsed do
      {:ok, seconds} -> [{key, seconds * 1_000_000_000} | filters]
      :error -> filters
    end
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_integer(value, default, minimum, maximum) do
    value =
      case parse_integer(value || "") do
        {:ok, integer} -> integer
        :error -> default
      end

    value = max(value, minimum)
    if maximum == :infinity, do: value, else: min(value, maximum)
  end

  defp normalize_dashboard_params(params, nav) do
    params
    |> Enum.map(fn
      {"name", value} -> {:name, value}
      {"service", value} -> {:service, value}
      {"kind", value} -> {:kind, value}
      {"status", value} -> {:status, value}
      {"p", value} -> {:p, value}
      {"per_page", value} -> {:per_page, value}
      {"trace_id", value} -> {:trace_id, value}
      {"since", value} -> {:since, value}
      {"until", value} -> {:until, value}
      {_key, _value} -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{})
    |> Map.put(:nav, nav)
  end

  @impl true
  def handle_event("search", params, socket) do
    nav_params = %{
      nav: "search",
      name: Map.get(params, "name", ""),
      service: Map.get(params, "service", ""),
      kind: Map.get(params, "kind", ""),
      status: Map.get(params, "status", ""),
      window: Map.get(params, "window", @default_window),
      p: "1",
      per_page: to_string(socket.assigns.per_page)
    }

    to = live_dashboard_path(socket, socket.assigns.page, nav_params)
    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("clear", _, socket) do
    params = %{nav: "search", name: "", service: "", kind: "", status: "", p: "1"}
    to = live_dashboard_path(socket, socket.assigns.page, params)
    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("lookup_trace", %{"trace_id" => trace_id}, socket) do
    params = %{nav: "traces", trace_id: trace_id}
    to = live_dashboard_path(socket, socket.assigns.page, params)
    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("toggle_span_detail", %{"span_id" => span_id}, socket) do
    expanded = socket.assigns.expanded_spans

    expanded =
      if MapSet.member?(expanded, span_id),
        do: MapSet.delete(expanded, span_id),
        else: MapSet.put(expanded, span_id)

    details =
      if MapSet.member?(expanded, span_id) and
           not Map.has_key?(socket.assigns.expanded_span_details, span_id) do
        case Enum.find(socket.assigns.trace_spans, &(&1.span_id == span_id)) do
          nil ->
            socket.assigns.expanded_span_details

          span ->
            Map.put(
              socket.assigns.expanded_span_details,
              span_id,
              Components.prepare_span_detail(span)
            )
        end
      else
        socket.assigns.expanded_span_details
      end

    {:noreply, assign(socket, expanded_spans: expanded, expanded_span_details: details)}
  end

  def handle_event("toggle_tail", _, socket) do
    if socket.assigns.subscribed do
      case HistoricalSource.unsubscribe() do
        :ok -> {:noreply, assign(socket, subscribed: false, tail_error: nil)}
        {:error, reason} -> {:noreply, assign(socket, tail_error: inspect(reason))}
      end
    else
      case HistoricalSource.subscribe() do
        :ok ->
          {:noreply,
           socket
           |> assign(subscribed: true, tail_count: 0, tail_error: nil)
           |> stream(:tail_entries, [], reset: true)}

        {:error, reason} ->
          {:noreply, assign(socket, tail_error: inspect(reason))}
      end
    end
  end

  @impl true
  def handle_refresh(socket) do
    nav = resolve_nav(socket.assigns.page.params)

    socket =
      case nav do
        "stats" -> apply_nav("stats", %{}, socket)
        _ -> socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:timeless_traces, :span, span},
        %{assigns: %{subscribed: true, nav: "tail"}} = socket
      ) do
    row = Components.prepare_span_row(span)

    {:noreply,
     socket
     |> stream_insert(:tail_entries, row, at: 0, limit: @tail_cap)
     |> update(:tail_count, &min(&1 + 1, @tail_cap))}
  end

  def handle_info({:timeless_dashboard_async, key, ref, result}, socket) do
    case Map.get(socket.assigns.async_refs, key) do
      {^ref, _pid} ->
        socket = update(socket, :async_refs, &Map.delete(&1, key))
        {:noreply, apply_async_result(key, result, socket)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp apply_async_result(:search, {:ok, {:ok, %{entries: entries} = result}}, socket) do
    count = length(entries)

    assign(socket,
      entries: entries,
      entry_rows: Components.prepare_span_rows(entries),
      entry_count: count,
      total: Map.get(result, :total, count),
      has_more: Map.get(result, :has_more, count == socket.assigns.per_page),
      search_loading: false
    )
  end

  defp apply_async_result(:search, _result, socket) do
    assign(socket,
      entries: [],
      entry_rows: [],
      entry_count: 0,
      total: 0,
      has_more: false,
      search_loading: false
    )
  end

  defp apply_async_result(:trace, {:ok, {trace_id, {:ok, spans}, elapsed_us}}, socket) do
    if trace_id == socket.assigns.trace_id do
      assign(socket,
        trace_spans: spans,
        trace_view: Components.prepare_trace(spans),
        trace_loading: false,
        trace_lookup_us: elapsed_us
      )
    else
      socket
    end
  end

  defp apply_async_result(:trace, {:ok, {trace_id, _result, elapsed_us}}, socket) do
    if trace_id == socket.assigns.trace_id do
      assign(socket,
        trace_spans: [],
        trace_view: Components.prepare_trace([]),
        trace_loading: false,
        trace_lookup_us: elapsed_us
      )
    else
      socket
    end
  end

  defp apply_async_result(:trace, _result, socket), do: assign(socket, :trace_loading, false)

  defp apply_async_result(:stats, {:ok, {:ok, stats}}, socket),
    do: assign(socket, stats: stats, stats_loading: false)

  defp apply_async_result(:stats, _result, socket),
    do: assign(socket, stats: nil, stats_loading: false)

  @doc false
  def search_query_options(params) do
    name = Map.get(params, "name", "")
    service = Map.get(params, "service", "")
    {_kind, kind_filter} = enum_filter(Map.get(params, "kind", ""), @kinds)
    {_status, status_filter} = enum_filter(Map.get(params, "status", ""), @statuses)
    window = normalize_window(Map.get(params, "window", @default_window))
    per_page = parse_integer(Map.get(params, "per_page"), @default_per_page, 1, 100)
    current_page = parse_integer(Map.get(params, "p"), 1, 1, :infinity)

    build_filters(name, service, kind_filter, status_filter)
    |> add_time_filter(:since, Map.get(params, "since"), window_start(window))
    |> add_time_filter(:until, Map.get(params, "until"), "")
    |> Kernel.++(
      limit: per_page,
      offset: (current_page - 1) * per_page,
      order: :desc,
      count_total: false
    )
  end

  defp leave_tail(%{assigns: %{subscribed: true}} = socket, nav) when nav != "tail" do
    case HistoricalSource.unsubscribe() do
      :ok -> assign(socket, subscribed: false, tail_error: nil)
      {:error, reason} -> assign(socket, tail_error: inspect(reason))
    end
  end

  defp leave_tail(socket, _nav), do: socket

  defp run_async(socket, key, function) do
    socket = cancel_async_task(socket, key)
    ref = make_ref()

    pid =
      if connected?(socket) do
        owner = self()

        {:ok, pid} =
          Task.start_link(fn ->
            result =
              try do
                {:ok, function.()}
              catch
                kind, reason -> {:exit, {kind, reason, __STACKTRACE__}}
              end

            send(owner, {:timeless_dashboard_async, key, ref, result})
          end)

        pid
      end

    update(socket, :async_refs, &Map.put(&1, key, {ref, pid}))
  end

  defp cancel_async_task(socket, key) do
    case Map.get(socket.assigns.async_refs, key) do
      {_ref, pid} when is_pid(pid) ->
        Process.unlink(pid)
        Process.exit(pid, :shutdown)

      _other ->
        :ok
    end

    socket
  end
end
