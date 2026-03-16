defmodule TimelessTracesDashboard.Page do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: false

  import TimelessTracesDashboard.Components

  @tail_cap 200

  @impl true
  def menu_link(_, _) do
    {:ok, "TimelessTraces"}
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       entries: [],
       total: 0,
       stats: nil,
       trace_spans: [],
       trace_id_input: "",
       trace_id: nil,
       trace_lookup_us: nil,
       expanded_spans: MapSet.new(),
       tail_entries: [],
       subscribed: false,
       search: "",
       name: "",
       service: "",
       kind: "",
       status: "",
       per_page: 25,
       current_page: 1
     )}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :nav, Map.get(assigns.page.params, "nav", "search"))

    ~H"""
    <.live_nav_bar
      id="span-tabs"
      page={@page}
      extra_params={["search", "name", "service", "kind", "status", "p", "per_page", "trace_id", "since", "until"]}
    >
      <:item name="search" label="Search"><span></span></:item>
      <:item name="traces" label="Traces"><span></span></:item>
      <:item name="stats" label="Stats"><span></span></:item>
      <:item name="tail" label="Live Tail"><span></span></:item>
    </.live_nav_bar>
    <.search_tab
      :if={@nav == "search"}
      entries={@entries}
      total={@total}
      search={@search}
      name={@name}
      service={@service}
      kind={@kind}
      status={@status}
      current_page={@current_page}
      per_page={@per_page}
      page={@page}
      socket={@socket}
    />
    <.trace_tab
      :if={@nav == "traces"}
      spans={@trace_spans}
      trace_id_input={@trace_id_input}
      trace_id={@trace_id}
      lookup_us={@trace_lookup_us}
      expanded_spans={@expanded_spans}
      page={@page}
      socket={@socket}
    />
    <.stats_tab :if={@nav == "stats"} stats={@stats} />
    <.tail_tab :if={@nav == "tail"} entries={@tail_entries} subscribed={@subscribed} />
    """
  end

  @impl true
  def handle_params(params, _uri, socket) do
    nav = Map.get(params, "nav", "search")
    socket = apply_nav(nav, params, socket)
    {:noreply, socket}
  end

  defp apply_nav("search", params, socket) do
    search = Map.get(params, "search", "")
    name = Map.get(params, "name", "")
    service = Map.get(params, "service", "")
    kind = Map.get(params, "kind", "")
    status = Map.get(params, "status", "")
    since = Map.get(params, "since", "")
    until_param = Map.get(params, "until", "")
    per_page = params |> Map.get("per_page", "25") |> String.to_integer() |> max(1) |> min(100)
    current_page = params |> Map.get("p", "1") |> String.to_integer() |> max(1)
    offset = (current_page - 1) * per_page

    filters = build_filters(name, service, kind, status)

    # Convert seconds to nanoseconds for trace timestamp filtering
    filters =
      if since != "",
        do: [{:since, String.to_integer(since) * 1_000_000_000} | filters],
        else: filters

    filters =
      if until_param != "",
        do: [{:until, String.to_integer(until_param) * 1_000_000_000} | filters],
        else: filters

    query_opts = filters ++ [limit: per_page, offset: offset, order: :desc]

    case TimelessTraces.query(query_opts) do
      {:ok, %TimelessTraces.Result{entries: entries, total: total}} ->
        assign(socket,
          entries: entries,
          total: total,
          search: search,
          name: name,
          service: service,
          kind: kind,
          status: status,
          per_page: per_page,
          current_page: current_page
        )

      {:error, _} ->
        assign(socket,
          entries: [],
          total: 0,
          search: search,
          name: name,
          service: service,
          kind: kind,
          status: status,
          per_page: per_page,
          current_page: current_page
        )
    end
  end

  defp apply_nav("traces", params, socket) do
    trace_id = Map.get(params, "trace_id", "")

    if trace_id != "" do
      # Flush buffer so recently-arrived spans (e.g. from Live Tail) are indexed
      TimelessTraces.flush()

      start = System.monotonic_time(:microsecond)

      case TimelessTraces.trace(trace_id) do
        {:ok, spans} ->
          elapsed_us = System.monotonic_time(:microsecond) - start

          assign(socket,
            trace_spans: spans,
            trace_id_input: trace_id,
            trace_id: trace_id,
            trace_lookup_us: elapsed_us
          )

        {:error, _} ->
          elapsed_us = System.monotonic_time(:microsecond) - start

          assign(socket,
            trace_spans: [],
            trace_id_input: trace_id,
            trace_id: trace_id,
            trace_lookup_us: elapsed_us
          )
      end
    else
      assign(socket, trace_spans: [], trace_id_input: "", trace_id: nil, trace_lookup_us: nil)
    end
  end

  defp apply_nav("stats", _params, socket) do
    case TimelessTraces.stats() do
      {:ok, stats} -> assign(socket, :stats, stats)
      _ -> socket
    end
  end

  defp apply_nav("tail", _params, socket) do
    if connected?(socket) and not socket.assigns.subscribed do
      TimelessTraces.subscribe()
      assign(socket, subscribed: true, tail_entries: [])
    else
      socket
    end
  end

  defp apply_nav(_, _params, socket), do: socket

  defp build_filters(name, service, kind, status) do
    filters = []
    filters = if name != "", do: [{:name, name} | filters], else: filters
    filters = if service != "", do: [{:service, service} | filters], else: filters

    filters =
      if kind != "",
        do: [{:kind, String.to_existing_atom(kind)} | filters],
        else: filters

    filters =
      if status != "",
        do: [{:status, String.to_existing_atom(status)} | filters],
        else: filters

    filters
  end

  @impl true
  def handle_event("search", params, socket) do
    nav_params = %{
      nav: "search",
      name: Map.get(params, "name", ""),
      service: Map.get(params, "service", ""),
      kind: Map.get(params, "kind", ""),
      status: Map.get(params, "status", ""),
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

    {:noreply, assign(socket, :expanded_spans, expanded)}
  end

  def handle_event("toggle_tail", _, socket) do
    if socket.assigns.subscribed do
      TimelessTraces.unsubscribe()
      {:noreply, assign(socket, subscribed: false)}
    else
      TimelessTraces.subscribe()
      {:noreply, assign(socket, subscribed: true, tail_entries: [])}
    end
  end

  @impl true
  def handle_info({:timeless_traces, :span, span}, socket) do
    tail = [span | socket.assigns.tail_entries] |> Enum.take(@tail_cap)
    {:noreply, assign(socket, :tail_entries, tail)}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
