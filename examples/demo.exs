# Minimal Phoenix app to demo SpanStreamDashboard.
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
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser

    live_dashboard "/dashboard",
      additional_pages: [
        spans: SpanStreamDashboard.Page
      ]
  end
end

defmodule Demo.Endpoint do
  use Phoenix.Endpoint, otp_app: :span_stream_dashboard

  @session_options [
    store: :cookie,
    key: "_demo_key",
    signing_salt: "demo_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options
  plug Demo.Router
end

# --- Boot everything ---

# Phoenix needs a JSON library
Application.put_env(:phoenix, :json_library, Jason)

# Configure endpoint
Application.put_env(:span_stream_dashboard, Demo.Endpoint,
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
Application.stop(:span_stream)
Application.put_env(:span_stream, :storage, :memory)
Application.put_env(:span_stream, :flush_interval, 5_000)
Application.put_env(:span_stream, :max_buffer_size, 500)
Application.put_env(:span_stream, :compaction_interval, 10_000)
Application.put_env(:span_stream, :compaction_threshold, 500)
Application.put_env(:span_stream, :compaction_max_raw_age, 30)

# Start deps
{:ok, _} = Application.ensure_all_started(:phoenix_live_dashboard)

# Start PubSub (required by LiveView)
{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: Demo.PubSub}],
    strategy: :one_for_one
  )

# Restart SpanStream with memory config
{:ok, _} = Application.ensure_all_started(:span_stream)

# Start endpoint
{:ok, _} = Demo.Endpoint.start_link()

IO.puts("""

========================================
  SpanStreamDashboard Demo
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

Stream.interval(500)
|> Stream.each(fn _ ->
  # Generate 3-5 traces per tick, each with 2-5 spans
  trace_count = Enum.random(3..5)

  spans =
    Enum.flat_map(1..trace_count, fn _ ->
      trace_id = random_hex.(16)
      service = Enum.random(services)
      span_count = Enum.random(2..5)
      base_ts = System.system_time(:nanosecond)

      Enum.map(1..span_count, fn i ->
        ts = base_ts + i * 100_000
        duration = :rand.uniform(500_000_000)
        status = Enum.random([:ok, :ok, :ok, :ok, :error, :unset])

        %{
          trace_id: trace_id,
          span_id: random_hex.(8),
          parent_span_id: if(i == 1, do: nil, else: random_hex.(8)),
          name: Enum.random(names),
          kind: Enum.random(kinds),
          start_time: ts,
          end_time: ts + duration,
          status: status,
          status_message: if(status == :error, do: "internal error", else: nil),
          attributes: %{
            "service.name" => service,
            "http.method" => Enum.random(methods),
            "http.route" => Enum.random(routes),
            "http.status_code" => "#{Enum.random([200, 200, 200, 201, 400, 404, 500])}"
          },
          events: [],
          resource: %{"service.name" => service}
        }
      end)
    end)

  SpanStream.Buffer.ingest(spans)
end)
|> Stream.run()
