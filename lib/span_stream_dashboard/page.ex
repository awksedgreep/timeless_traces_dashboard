defmodule SpanStreamDashboard.Page do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: false

  import SpanStreamDashboard.Components

  @tail_cap 200

  @impl true
  def menu_link(_, _) do
    {:ok, "Spans"}
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
      extra_params={["search", "name", "service", "kind", "status", "p", "per_page", "trace_id"]}
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
    per_page = params |> Map.get("per_page", "25") |> String.to_integer() |> max(1) |> min(100)
    current_page = params |> Map.get("p", "1") |> String.to_integer() |> max(1)
    offset = (current_page - 1) * per_page

    filters = build_filters(name, service, kind, status)
    query_opts = filters ++ [limit: per_page, offset: offset, order: :desc]

    case SpanStream.query(query_opts) do
      {:ok, %SpanStream.Result{entries: entries, total: total}} ->
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
      SpanStream.flush()

      case SpanStream.trace(trace_id) do
        {:ok, spans} ->
          assign(socket, trace_spans: spans, trace_id_input: trace_id, trace_id: trace_id)

        {:error, _} ->
          assign(socket, trace_spans: [], trace_id_input: trace_id, trace_id: trace_id)
      end
    else
      assign(socket, trace_spans: [], trace_id_input: "", trace_id: nil)
    end
  end

  defp apply_nav("stats", _params, socket) do
    case SpanStream.stats() do
      {:ok, stats} -> assign(socket, :stats, stats)
      _ -> socket
    end
  end

  defp apply_nav("tail", _params, socket) do
    if connected?(socket) and not socket.assigns.subscribed do
      SpanStream.subscribe()
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

  def handle_event("toggle_tail", _, socket) do
    if socket.assigns.subscribed do
      SpanStream.unsubscribe()
      {:noreply, assign(socket, subscribed: false)}
    else
      SpanStream.subscribe()
      {:noreply, assign(socket, subscribed: true, tail_entries: [])}
    end
  end

  @impl true
  def handle_info({:span_stream, :span, span}, socket) do
    tail = [span | socket.assigns.tail_entries] |> Enum.take(@tail_cap)
    {:noreply, assign(socket, :tail_entries, tail)}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
