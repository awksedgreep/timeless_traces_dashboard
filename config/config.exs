import Config

# Disable OTel exporter — span_stream_dashboard doesn't need to export traces
config :opentelemetry, traces_exporter: :none
