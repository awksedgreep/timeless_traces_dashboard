defmodule SpanStreamDashboard do
  @moduledoc """
  Phoenix LiveDashboard page for browsing OpenTelemetry spans stored by SpanStream.

  ## Usage

  Add this page to your LiveDashboard router:

      live_dashboard "/dashboard",
        additional_pages: [
          spans: SpanStreamDashboard.Page
        ]

  ## Tabs

  1. **Search** — query spans with name, service, kind, status filters + pagination
  2. **Traces** — look up all spans in a trace by trace ID
  3. **Stats** — aggregate metrics (blocks, entries, size, timestamps)
  4. **Live Tail** — real-time streaming of new spans
  """
end
