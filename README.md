# TimelessTracesDashboard

Phoenix [LiveDashboard](https://github.com/phoenixframework/phoenix_live_dashboard) page for browsing OpenTelemetry spans stored by [TimelessTraces](https://github.com/awksedgreep/timeless_traces).

Provides four tabs:

- **Search** -- query spans with name, service, kind, and status filters + pagination
- **Traces** -- look up all spans in a trace by trace ID with waterfall visualization
- **Stats** -- aggregate metrics (blocks, entries, compressed size, index size, timestamps)
- **Live Tail** -- real-time streaming of new spans

## Installation

### Quick Start (Igniter)

```bash
mix igniter.install timeless_traces_dashboard
```

This automatically:
1. Adds `config :timeless_traces, data_dir: "priv/timeless_traces"` to your config
2. Adds `config :opentelemetry, traces_exporter: {TimelessTraces.Exporter, []}` to your config
3. Adds `import TimelessTracesDashboard.Router` to your router
4. Adds `timeless_traces_dashboard "/dashboard"` to your browser scope
5. Updates your `.formatter.exs`

For in-memory storage (traces lost on restart):

```bash
mix igniter.install timeless_traces_dashboard --storage memory
```

### Manual Setup

Add `timeless_traces_dashboard` to your dependencies:

```elixir
def deps do
  [
    {:timeless_traces_dashboard, "~> 0.2.0"}
  ]
end
```

Configure TimelessTraces and OpenTelemetry in `config/config.exs`:

```elixir
config :timeless_traces, data_dir: "priv/timeless_traces"
config :opentelemetry, traces_exporter: {TimelessTraces.Exporter, []}
```

Add the router macro:

```elixir
# lib/my_app_web/router.ex
import TimelessTracesDashboard.Router

scope "/" do
  pipe_through :browser
  timeless_traces_dashboard "/dashboard"
end
```

Or add the page directly to an existing LiveDashboard:

```elixir
live_dashboard "/dashboard",
  additional_pages: [
    traces: TimelessTracesDashboard.Page
  ]
```

Navigate to `/dashboard/traces` in your browser.

## Requirements

- [TimelessTraces](https://github.com/awksedgreep/timeless_traces) must be running in your application
- Phoenix LiveDashboard ~> 0.8
- Phoenix LiveView ~> 1.0

## License

MIT
