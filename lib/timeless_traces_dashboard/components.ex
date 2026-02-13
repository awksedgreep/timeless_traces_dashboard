defmodule TimelessTracesDashboard.Components do
  @moduledoc false
  use Phoenix.Component

  # --- Search tab ---

  attr(:entries, :list, required: true)
  attr(:total, :integer, required: true)
  attr(:search, :string, required: true)
  attr(:name, :string, required: true)
  attr(:service, :string, required: true)
  attr(:kind, :string, required: true)
  attr(:status, :string, required: true)
  attr(:current_page, :integer, required: true)
  attr(:per_page, :integer, required: true)
  attr(:page, :any, required: true)
  attr(:socket, :any, required: true)

  def search_tab(assigns) do
    total_pages = max(1, ceil(assigns.total / assigns.per_page))
    kinds = ~w(internal server client producer consumer)
    statuses = ~w(ok error unset)

    assigns =
      assigns
      |> assign(:total_pages, total_pages)
      |> assign(:kinds, kinds)
      |> assign(:statuses, statuses)

    ~H"""
    <div class="mb-4">
      <div class="d-flex align-items-end mb-3 flex-wrap" style="gap: 0.75rem;">
        <form phx-submit="search" class="d-flex align-items-end flex-wrap" style="gap: 0.75rem;">
          <div>
            <label class="form-label mb-1"><small>Name</small></label>
            <input
              type="text"
              name="name"
              value={@name}
              placeholder="Span name..."
              class="form-control form-control-sm"
              style="min-width: 180px;"
            />
          </div>
          <div>
            <label class="form-label mb-1"><small>Service</small></label>
            <input
              type="text"
              name="service"
              value={@service}
              placeholder="Service name..."
              class="form-control form-control-sm"
              style="min-width: 150px;"
            />
          </div>
          <div>
            <label class="form-label mb-1"><small>Kind</small></label>
            <select name="kind" class="form-select form-select-sm" style="min-width: 110px;">
              <option value="" selected={@kind == ""}>All</option>
              <option :for={k <- @kinds} value={k} selected={@kind == k}>
                {String.capitalize(k)}
              </option>
            </select>
          </div>
          <div>
            <label class="form-label mb-1"><small>Status</small></label>
            <select name="status" class="form-select form-select-sm" style="min-width: 100px;">
              <option value="" selected={@status == ""}>All</option>
              <option :for={s <- @statuses} value={s} selected={@status == s}>
                {String.capitalize(s)}
              </option>
            </select>
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Search</button>
        </form>
        <button phx-click="clear" class="btn btn-outline-secondary btn-sm">Clear</button>
      </div>

      <div class="card">
        <div class="card-body p-0">
          <div class="d-flex justify-content-between align-items-center px-3 py-2">
            <small class="text-muted">
              {@total} {if @total == 1, do: "span", else: "spans"}
            </small>
            <small class="text-muted">
              Page {@current_page} of {@total_pages}
            </small>
          </div>
          <table class="table table-sm table-hover mb-0">
            <thead>
              <tr>
                <th style="width: 160px;">Start Time</th>
                <th>Name</th>
                <th style="width: 130px;">Service</th>
                <th style="width: 80px;">Kind</th>
                <th style="width: 70px;">Status</th>
                <th style="width: 90px;">Duration</th>
                <th style="width: 140px;">Trace ID</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@entries == []}>
                <td colspan="7" class="text-center text-muted py-4">No spans found.</td>
              </tr>
              <.span_row :for={span <- @entries} span={span} />
            </tbody>
          </table>
          <.pagination
            :if={@total_pages > 1}
            current_page={@current_page}
            total_pages={@total_pages}
            page={@page}
            socket={@socket}
            name={@name}
            service={@service}
            kind={@kind}
            status={@status}
            per_page={@per_page}
          />
        </div>
      </div>
    </div>
    """
  end

  attr(:span, :any, required: true)

  defp span_row(assigns) do
    trace_id = assigns.span.trace_id || ""
    assigns = assign(assigns, :trace_id, trace_id)

    ~H"""
    <tr>
      <td class="text-monospace" style="font-size: 0.8rem;">
        {format_timestamp(@span.start_time)}
      </td>
      <td style="max-width: 250px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
        {@span.name}
      </td>
      <td style="font-size: 0.85rem;">
        {get_service(@span)}
      </td>
      <td><.kind_badge kind={@span.kind} /></td>
      <td><.status_badge status={@span.status} /></td>
      <td class="text-monospace" style="font-size: 0.8rem;">
        {format_duration(@span.duration_ns)}
      </td>
      <td style="font-size: 0.75rem; font-family: monospace;" title={@trace_id}>
        <a
          href="#"
          phx-click="lookup_trace"
          phx-value-trace_id={@trace_id}
          style="text-decoration: none; cursor: pointer;"
        >
          {String.slice(@trace_id, 0..11)}<span class="text-muted">...</span>
        </a>
      </td>
    </tr>
    """
  end

  attr(:kind, :any, required: true)

  defp kind_badge(assigns) do
    color =
      case to_string(assigns.kind) do
        "server" -> "primary"
        "client" -> "success"
        "producer" -> "warning"
        "consumer" -> "info"
        _ -> "secondary"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge bg-#{@color}"} style="font-size: 0.7rem;">
      {@kind}
    </span>
    """
  end

  attr(:status, :any, required: true)

  defp status_badge(assigns) do
    color =
      case to_string(assigns.status) do
        "error" -> "danger"
        "ok" -> "success"
        _ -> "secondary"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge bg-#{@color}"} style="font-size: 0.7rem;">
      {@status}
    </span>
    """
  end

  attr(:current_page, :integer, required: true)
  attr(:total_pages, :integer, required: true)
  attr(:page, :any, required: true)
  attr(:socket, :any, required: true)
  attr(:name, :string, required: true)
  attr(:service, :string, required: true)
  attr(:kind, :string, required: true)
  attr(:status, :string, required: true)
  attr(:per_page, :integer, required: true)

  defp pagination(assigns) do
    ~H"""
    <nav class="d-flex justify-content-center py-2">
      <ul class="pagination pagination-sm mb-0">
        <li class={"page-item #{if @current_page <= 1, do: "disabled"}"}>
          <.link
            patch={
              page_path(@socket, @page, @current_page - 1, @name, @service, @kind, @status, @per_page)
            }
            class="page-link"
          >
            Prev
          </.link>
        </li>
        <li class="page-item disabled">
          <span class="page-link">{@current_page} / {@total_pages}</span>
        </li>
        <li class={"page-item #{if @current_page >= @total_pages, do: "disabled"}"}>
          <.link
            patch={
              page_path(@socket, @page, @current_page + 1, @name, @service, @kind, @status, @per_page)
            }
            class="page-link"
          >
            Next
          </.link>
        </li>
      </ul>
    </nav>
    """
  end

  defp page_path(socket, page, page_num, name, service, kind, status, per_page) do
    Phoenix.LiveDashboard.PageBuilder.live_dashboard_path(socket, page, %{
      nav: "search",
      name: name,
      service: service,
      kind: kind,
      status: status,
      p: to_string(page_num),
      per_page: to_string(per_page)
    })
  end

  # --- Trace tab ---

  @service_colors [
    "#4e79a7",
    "#f28e2b",
    "#e15759",
    "#76b7b2",
    "#59a14f",
    "#edc948",
    "#b07aa1",
    "#ff9da7",
    "#9c755f",
    "#bab0ac"
  ]

  attr(:spans, :list, required: true)
  attr(:trace_id_input, :string, required: true)
  attr(:trace_id, :any, required: true)
  attr(:lookup_us, :any, default: nil)

  def trace_tab(assigns) do
    assigns =
      if assigns.trace_id && assigns.spans != [] do
        tree = build_span_tree(assigns.spans)
        flat = flatten_tree(tree, 0)
        trace_start = assigns.spans |> Enum.map(& &1.start_time) |> Enum.min()
        trace_end = assigns.spans |> Enum.map(& &1.end_time) |> Enum.max()
        trace_dur = max(1, trace_end - trace_start)

        services =
          assigns.spans
          |> Enum.map(&get_service/1)
          |> Enum.uniq()
          |> Enum.with_index()
          |> Map.new(fn {svc, i} ->
            {svc, Enum.at(@service_colors, rem(i, length(@service_colors)))}
          end)

        assigns
        |> assign(:tree_rows, flat)
        |> assign(:trace_start, trace_start)
        |> assign(:trace_dur, trace_dur)
        |> assign(:service_colors, services)
      else
        assigns
        |> assign(:tree_rows, [])
        |> assign(:trace_start, 0)
        |> assign(:trace_dur, 1)
        |> assign(:service_colors, %{})
      end

    ~H"""
    <div class="mb-4">
      <form phx-submit="lookup_trace" class="d-flex align-items-end mb-3" style="gap: 0.75rem;">
        <div>
          <label class="form-label mb-1"><small>Trace ID</small></label>
          <input
            type="text"
            name="trace_id"
            value={@trace_id_input}
            placeholder="Enter trace ID..."
            class="form-control form-control-sm"
            style="min-width: 360px; font-family: monospace;"
          />
        </div>
        <button type="submit" class="btn btn-primary btn-sm">Lookup</button>
      </form>

      <div :if={@trace_id && @spans != []} class="card">
        <div class="card-body p-0">
          <div class="d-flex justify-content-between align-items-center px-3 py-2 border-bottom">
            <div>
              <span class="fw-semibold" style="font-size: 0.9rem;">Trace</span>
              <code class="ms-1" style="font-size: 0.8rem;">{@trace_id}</code>
            </div>
            <div class="d-flex align-items-center" style="gap: 1rem;">
              <small class="text-muted">
                {length(@spans)} {if length(@spans) == 1, do: "span", else: "spans"}
              </small>
              <small :if={@lookup_us} class="text-muted" title="Trace lookup time">
                {format_lookup_time(@lookup_us)}
              </small>
              <span class="fw-semibold" style="font-size: 0.85rem;">
                {format_duration(trace_duration(@spans))}
              </span>
            </div>
          </div>
          <%!-- Service legend --%>
          <div class="d-flex flex-wrap px-3 py-2 border-bottom" style="gap: 0.75rem;">
            <div
              :for={{svc, color} <- @service_colors}
              class="d-flex align-items-center"
              style="gap: 0.3rem;"
            >
              <span style={"width: 10px; height: 10px; border-radius: 2px; background: #{color}; display: inline-block;"}>
              </span>
              <small style="font-size: 0.75rem;">{svc}</small>
            </div>
          </div>
          <%!-- Timeline header --%>
          <div class="d-flex border-bottom" style="font-size: 0.7rem; color: #888;">
            <div style="width: 38%; min-width: 280px; padding: 4px 12px;">
              Service / Operation
            </div>
            <div class="flex-grow-1 d-flex justify-content-between px-2" style="padding: 4px 0;">
              <span>0ms</span>
              <span>{format_duration(div(@trace_dur, 4))}</span>
              <span>{format_duration(div(@trace_dur, 2))}</span>
              <span>{format_duration(div(@trace_dur * 3, 4))}</span>
              <span>{format_duration(@trace_dur)}</span>
            </div>
          </div>
          <%!-- Span rows --%>
          <div :for={{span, depth} <- @tree_rows} class="waterfall-row d-flex border-bottom"
               style={"font-size: 0.8rem; #{if span.status == :error, do: "background: #fff5f5;", else: ""}"}>
            <%!-- Left panel: service + name --%>
            <div style={"width: 38%; min-width: 280px; padding: 6px 12px; padding-left: #{12 + depth * 16}px; overflow: hidden; white-space: nowrap; text-overflow: ellipsis;"}>
              <span
                :if={depth > 0}
                class="text-muted me-1"
                style="font-size: 0.7rem;"
              >&#x2514;</span>
              <span
                style={"color: #{Map.get(@service_colors, get_service(span), "#888")}; font-weight: 600; font-size: 0.75rem;"}
              >{get_service(span)}</span>
              <span class="text-muted mx-1" style="font-size: 0.65rem;">&#x25B8;</span>
              <span title={span.name}>{span.name}</span>
              <.status_dot status={span.status} />
            </div>
            <%!-- Right panel: waterfall bar --%>
            <div class="flex-grow-1 position-relative" style="padding: 4px 8px;">
              <% offset_pct = (span.start_time - @trace_start) / @trace_dur * 100 %>
              <% width_pct = max(0.3, span.duration_ns / @trace_dur * 100) %>
              <div
                style={"position: absolute; top: 5px; bottom: 5px; left: #{offset_pct}%; width: #{width_pct}%; background: #{Map.get(@service_colors, get_service(span), "#888")}; border-radius: 3px; min-width: 2px; opacity: 0.85;"}
                title={"#{span.name} — #{format_duration(span.duration_ns)}"}
              >
                <span
                  :if={width_pct > 8}
                  style="position: absolute; left: 4px; top: 50%; transform: translateY(-50%); font-size: 0.65rem; color: #fff; font-weight: 600; white-space: nowrap;"
                >
                  {format_duration(span.duration_ns)}
                </span>
              </div>
              <span
                :if={width_pct <= 8}
                style={"position: absolute; top: 50%; transform: translateY(-50%); left: #{offset_pct + width_pct + 0.5}%; font-size: 0.65rem; color: #666; white-space: nowrap;"}
              >
                {format_duration(span.duration_ns)}
              </span>
            </div>
          </div>
          <%!-- Empty state within card (shouldn't happen but just in case) --%>
        </div>
      </div>

      <div :if={@trace_id && @spans == []} class="card">
        <div class="card-body text-center text-muted py-4">
          No spans found for this trace.
        </div>
      </div>

      <div :if={@trace_id == nil} class="text-center text-muted py-4">
        Enter a trace ID to view all spans in that trace.
      </div>
    </div>
    """
  end

  attr(:status, :any, required: true)

  defp status_dot(assigns) do
    color =
      case to_string(assigns.status) do
        "error" -> "#dc3545"
        "ok" -> "#198754"
        _ -> nil
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span
      :if={@color}
      style={"display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: #{@color}; margin-left: 4px; vertical-align: middle;"}
      title={to_string(@status)}
    >
    </span>
    """
  end

  # Build a tree of spans from parent_span_id relationships
  defp build_span_tree(spans) do
    by_id = Map.new(spans, &{&1.span_id, &1})
    children_map = Enum.group_by(spans, & &1.parent_span_id)

    roots =
      spans
      |> Enum.filter(fn s ->
        s.parent_span_id == nil or not Map.has_key?(by_id, s.parent_span_id)
      end)
      |> Enum.sort_by(& &1.start_time)

    Enum.map(roots, fn root -> {root, build_children(root.span_id, children_map)} end)
  end

  defp build_children(span_id, children_map) do
    (Map.get(children_map, span_id) || [])
    |> Enum.sort_by(& &1.start_time)
    |> Enum.map(fn child -> {child, build_children(child.span_id, children_map)} end)
  end

  # Flatten tree into [{span, depth}] for rendering
  defp flatten_tree(nodes, depth) do
    Enum.flat_map(nodes, fn {span, children} ->
      [{span, depth} | flatten_tree(children, depth + 1)]
    end)
  end

  # --- Stats tab ---

  attr(:stats, :any, required: true)

  def stats_tab(assigns) do
    ~H"""
    <div :if={@stats == nil} class="text-center text-muted py-4">
      Loading stats...
    </div>
    <div :if={@stats} class="row">
      <div class="col-sm-4 mb-3">
        <div class="card">
          <div class="card-body text-center">
            <h6 class="card-subtitle text-muted mb-1">Total Spans</h6>
            <h4 class="mb-0">{@stats.total_entries}</h4>
          </div>
        </div>
      </div>
      <div class="col-sm-4 mb-3">
        <div class="card">
          <div class="card-body text-center">
            <h6 class="card-subtitle text-muted mb-1">Total Size</h6>
            <h4 class="mb-0">{format_bytes(@stats.total_bytes)}</h4>
          </div>
        </div>
      </div>
      <div class="col-sm-4 mb-3">
        <div class="card">
          <div class="card-body text-center">
            <h6 class="card-subtitle text-muted mb-1">Storage Mode</h6>
            <h4 class="mb-0">
              <span class="badge bg-info">{TimelessTraces.Config.storage()}</span>
            </h4>
          </div>
        </div>
      </div>
      <div class="col-sm-4 mb-3">
        <div class="card">
          <div class="card-body text-center">
            <h6 class="card-subtitle text-muted mb-1">Raw Blocks</h6>
            <h4 class="mb-0">
              {@stats.raw_blocks}
              <small class="text-muted" style="font-size: 0.6em;">
                ({format_bytes(@stats.raw_bytes)})
              </small>
            </h4>
          </div>
        </div>
      </div>
      <div class="col-sm-4 mb-3">
        <div class="card">
          <div class="card-body text-center">
            <h6 class="card-subtitle text-muted mb-1">Compressed Blocks</h6>
            <h4 class="mb-0">
              {@stats.zstd_blocks}
              <small class="text-muted" style="font-size: 0.6em;">
                ({format_bytes(@stats.zstd_bytes)})
              </small>
            </h4>
          </div>
        </div>
      </div>
      <div class="col-sm-4 mb-3">
        <div class="card">
          <div class="card-body text-center">
            <h6 class="card-subtitle text-muted mb-1">Compression Ratio</h6>
            <h4 class="mb-0">
              {if @stats.zstd_entries > 0 and @stats.raw_entries > 0 do
                raw_per = @stats.raw_bytes / @stats.raw_entries
                zstd_per = @stats.zstd_bytes / @stats.zstd_entries
                ratio = raw_per / zstd_per
                pct = Float.round((1 - 1 / ratio) * 100, 1)
                "#{Float.round(ratio, 1)}x (#{pct}%)"
              else
                if @stats.zstd_blocks > 0, do: "compressed", else: "pending"
              end}
            </h4>
          </div>
        </div>
      </div>
      <div class="col-sm-4 mb-3">
        <div class="card">
          <div class="card-body text-center">
            <h6 class="card-subtitle text-muted mb-1">Oldest Span</h6>
            <h4 class="mb-0" style="font-size: 1rem;">
              {format_timestamp(@stats.oldest_timestamp)}
            </h4>
          </div>
        </div>
      </div>
      <div class="col-sm-4 mb-3">
        <div class="card">
          <div class="card-body text-center">
            <h6 class="card-subtitle text-muted mb-1">Newest Span</h6>
            <h4 class="mb-0" style="font-size: 1rem;">
              {format_timestamp(@stats.newest_timestamp)}
            </h4>
          </div>
        </div>
      </div>
      <div class="col-sm-4 mb-3">
        <div class="card">
          <div class="card-body text-center">
            <h6 class="card-subtitle text-muted mb-1">Index Size</h6>
            <h4 class="mb-0">{format_bytes(@stats.index_size)}</h4>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Live Tail tab ---

  attr(:entries, :list, required: true)
  attr(:subscribed, :boolean, required: true)

  def tail_tab(assigns) do
    ~H"""
    <div class="mb-4">
      <div class="d-flex align-items-center mb-3" style="gap: 0.75rem;">
        <button
          phx-click="toggle_tail"
          class={"btn btn-sm #{if @subscribed, do: "btn-danger", else: "btn-success"}"}
        >
          {if @subscribed, do: "Stop", else: "Start"}
        </button>
        <small class="text-muted">
          <%= if @subscribed do %>
            Streaming... ({length(@entries)} spans)
          <% else %>
            Paused
          <% end %>
        </small>
      </div>

      <div class="card">
        <div class="card-body p-0">
          <table class="table table-sm table-hover mb-0">
            <thead>
              <tr>
                <th style="width: 160px;">Start Time</th>
                <th>Name</th>
                <th style="width: 130px;">Service</th>
                <th style="width: 80px;">Kind</th>
                <th style="width: 70px;">Status</th>
                <th style="width: 90px;">Duration</th>
                <th style="width: 140px;">Trace ID</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@entries == []}>
                <td colspan="7" class="text-center text-muted py-4">
                  {if @subscribed,
                    do: "Waiting for spans...",
                    else: "Click Start to begin streaming."}
                </td>
              </tr>
              <.span_row :for={span <- @entries} span={span} />
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp get_service(span) do
    Map.get(span.attributes || %{}, "service.name") ||
      Map.get(span.resource || %{}, "service.name") ||
      ""
  end

  defp format_timestamp(nil), do: "-"

  defp format_timestamp(ts) when is_integer(ts) do
    # TimelessTraces timestamps are in nanoseconds
    case ts > 1_000_000_000_000_000_000 do
      true ->
        secs = div(ts, 1_000_000_000)

        case DateTime.from_unix(secs) do
          {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
          _ -> to_string(ts)
        end

      false ->
        # Assume seconds
        case DateTime.from_unix(ts) do
          {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
          _ -> to_string(ts)
        end
    end
  end

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_timestamp(other), do: to_string(other)

  defp format_duration(nil), do: "-"
  defp format_duration(0), do: "0ns"

  defp format_duration(ns) when is_integer(ns) do
    cond do
      ns >= 1_000_000_000 -> "#{Float.round(ns / 1_000_000_000, 2)}s"
      ns >= 1_000_000 -> "#{Float.round(ns / 1_000_000, 1)}ms"
      ns >= 1_000 -> "#{Float.round(ns / 1_000, 1)}us"
      true -> "#{ns}ns"
    end
  end

  defp format_duration(_), do: "-"

  defp format_lookup_time(us) when us >= 1000, do: "found in #{Float.round(us / 1000, 1)}ms"
  defp format_lookup_time(us), do: "found in #{us}us"

  defp trace_duration([]), do: 0

  defp trace_duration(spans) do
    min_start = spans |> Enum.map(& &1.start_time) |> Enum.min()
    max_end = spans |> Enum.map(& &1.end_time) |> Enum.max()
    max(0, max_end - min_start)
  end

  defp format_bytes(nil), do: "-"
  defp format_bytes(0), do: "0 B"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end
end
