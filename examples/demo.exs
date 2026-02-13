# Minimal Phoenix app to demo TimelessTracesDashboard.
#
# Run:  mix run examples/demo.exs
# Open: http://localhost:4050/dashboard/spans
# Stop: Ctrl+C twice

Logger.configure(level: :info)

# --- Phoenix Endpoint + Router ---

defmodule Demo.ErrorHTML do
  def render(template, _assigns), do: "Error: #{template}"
end

defmodule Demo.Router do
  use Phoenix.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/" do
    pipe_through(:browser)

    live_dashboard("/dashboard",
      additional_pages: [
        spans: TimelessTracesDashboard.Page
      ]
    )
  end
end

defmodule Demo.Endpoint do
  use Phoenix.Endpoint, otp_app: :timeless_traces_dashboard

  @session_options [
    store: :cookie,
    key: "_demo_key",
    signing_salt: "demo_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(Demo.Router)
end

# --- Boot everything ---

# Phoenix needs a JSON library
Application.put_env(:phoenix, :json_library, Jason)

# Configure endpoint
Application.put_env(:timeless_traces_dashboard, Demo.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [port: 4050],
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "demo_lv_salt"],
  pubsub_server: Demo.PubSub,
  render_errors: [formats: [html: Demo.ErrorHTML], layout: false],
  debug_errors: true,
  server: true
)

# Stop span_stream (auto-started by mix run with disk defaults),
# reconfigure for in-memory mode, then restart
Application.stop(:timeless_traces)
Application.put_env(:timeless_traces, :storage, :memory)
Application.put_env(:timeless_traces, :flush_interval, 5_000)
Application.put_env(:timeless_traces, :max_buffer_size, 500)
Application.put_env(:timeless_traces, :compaction_interval, 10_000)
Application.put_env(:timeless_traces, :compaction_threshold, 500)
Application.put_env(:timeless_traces, :compaction_max_raw_age, 30)

# Start deps
{:ok, _} = Application.ensure_all_started(:phoenix_live_dashboard)

# Start PubSub (required by LiveView)
{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: Demo.PubSub}],
    strategy: :one_for_one
  )

# Restart TimelessTraces with memory config
{:ok, _} = Application.ensure_all_started(:timeless_traces)

# Start endpoint
{:ok, _} = Demo.Endpoint.start_link()

IO.puts("""

========================================
  TimelessTracesDashboard Demo
  http://localhost:4050/dashboard/spans
========================================

Generating sample spans every second...
Press Ctrl+C twice to stop.
""")

# Generate sample span data in a loop
services = ~w(api-gateway user-service order-service payment-service)
names = ~w(HTTP\ GET HTTP\ POST db.query cache.get queue.publish grpc.call)
kinds = [:server, :client, :internal, :producer, :consumer]
methods = ~w(GET GET GET POST PUT DELETE)
routes = ~w(/api/users /api/orders /api/products /api/checkout /health)

random_hex = fn n -> :crypto.strong_rand_bytes(n) |> Base.encode16(case: :lower) end

# Build a realistic trace: root span encompasses the full request, child spans
# are staggered within the parent's duration to show a proper waterfall.
build_trace = fn ->
  trace_id = random_hex.(16)
  span_count = Enum.random(3..6)
  root_service = Enum.random(services)
  root_name = "#{Enum.random(methods)} #{Enum.random(routes)}"
  root_id = random_hex.(8)
  base_ts = System.system_time(:nanosecond)
  # Root spans 50-800ms
  root_duration = Enum.random(50_000_000..800_000_000)

  root_span = %{
    trace_id: trace_id,
    span_id: root_id,
    parent_span_id: nil,
    name: root_name,
    kind: :server,
    start_time: base_ts,
    end_time: base_ts + root_duration,
    status: Enum.random([:ok, :ok, :ok, :ok, :error, :unset]),
    status_message: nil,
    attributes: %{
      "service.name" => root_service,
      "http.method" => Enum.random(methods),
      "http.route" => Enum.random(routes),
      "http.status_code" => "#{Enum.random([200, 200, 200, 201, 400, 404, 500])}"
    },
    events: [],
    resource: %{"service.name" => root_service}
  }

  # Child spans staggered within the root's duration
  {child_spans, _} =
    Enum.map_reduce(1..(span_count - 1), {root_id, base_ts}, fn _i, {parent_id, cursor} ->
      child_id = random_hex.(8)
      child_service = Enum.random(services)
      # Gap before this span starts (5-15% of remaining time)
      remaining = root_duration - (cursor - base_ts)
      gap = Enum.random(max(1, div(remaining, 20))..max(2, div(remaining, 6)))
      child_start = cursor + gap
      # Duration: 10-60% of remaining time after gap
      max_dur = max(1_000_000, remaining - gap)

      child_duration =
        Enum.random(div(max_dur, 10)..max(div(max_dur, 10) + 1, div(max_dur * 6, 10)))

      child_end = min(child_start + child_duration, base_ts + root_duration)
      status = Enum.random([:ok, :ok, :ok, :ok, :error, :unset])

      # Alternate between children of root and children of previous span
      actual_parent = if Enum.random(0..2) == 0, do: root_id, else: parent_id

      span = %{
        trace_id: trace_id,
        span_id: child_id,
        parent_span_id: actual_parent,
        name: Enum.random(names),
        kind: Enum.random(kinds),
        start_time: child_start,
        end_time: child_end,
        status: status,
        status_message: if(status == :error, do: "internal error", else: nil),
        attributes: %{
          "service.name" => child_service,
          "http.method" => Enum.random(methods),
          "http.route" => Enum.random(routes),
          "http.status_code" => "#{Enum.random([200, 200, 200, 201, 400, 404, 500])}"
        },
        events: [],
        resource: %{"service.name" => child_service}
      }

      {span, {child_id, child_start + div(child_duration, 3)}}
    end)

  [root_span | child_spans]
end

Stream.interval(500)
|> Stream.each(fn _ ->
  trace_count = Enum.random(3..5)

  spans = Enum.flat_map(1..trace_count, fn _ -> build_trace.() end)

  TimelessTraces.Buffer.ingest(spans)
end)
|> Stream.run()
