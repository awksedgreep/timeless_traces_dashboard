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

## Existing OpenTelemetry Exporter

OpenTelemetry's `:traces_exporter` config only supports a **single exporter**. If you already export traces to an external system (Jaeger, Tempo, Datadog, etc.), setting `traces_exporter: {TimelessTraces.Exporter, []}` will **replace** your existing exporter and traces will stop flowing to that system.

If you need traces sent to both TimelessTraces and an external collector, you'll need a thin fan-out exporter that calls both. For example:

```elixir
defmodule MyApp.CompositeExporter do
  @behaviour :otel_exporter_traces

  @impl true
  def init(_config) do
    {:ok, otel_state} = :otel_exporter_otlp.init(%{})
    {:ok, timeless_state} = TimelessTraces.Exporter.init(%{})
    {:ok, %{otlp: otel_state, timeless: timeless_state}}
  end

  @impl true
  def export(tab, resource, state) do
    :otel_exporter_otlp.export(tab, resource, state.otlp)
    TimelessTraces.Exporter.export(tab, resource, state.timeless)
    {:ok, state}
  end

  @impl true
  def shutdown(state) do
    :otel_exporter_otlp.shutdown(state.otlp)
    TimelessTraces.Exporter.shutdown(state.timeless)
    :ok
  end
end
```

Then configure: `config :opentelemetry, traces_exporter: {MyApp.CompositeExporter, []}`

This does not apply to metrics or logs -- the metrics Reporter uses `:telemetry` (which supports multiple handlers) and TimelessLogs registers as a Logger handler (which coexists with other handlers).

## Requirements

- [TimelessTraces](https://github.com/awksedgreep/timeless_traces) must be running in your application
- Phoenix LiveDashboard ~> 0.8
- Phoenix LiveView ~> 1.0

## License

MIT
