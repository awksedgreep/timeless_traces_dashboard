defmodule TimelessTracesDashboard.HistoricalSource do
  @moduledoc """
  Opt-in boundary for historical dashboard search and trace detail.

  Live tail, statistics, alerts, backup, auth policy, and UI state deliberately
  remain on their existing Elixir paths.
  """

  @callback query(keyword(), keyword()) ::
              {:ok, TimelessTraces.Result.t()} | {:error, term()}
  @callback trace(String.t(), keyword()) ::
              {:ok, [TimelessTraces.Span.t()]} | {:error, term()}

  @default TimelessTracesDashboard.HistoricalSource.Local

  def query(filters), do: call(:query, [filters])
  def trace(trace_id), do: call(:trace, [trace_id])

  defp call(function, args) do
    case Application.get_env(:timeless_traces_dashboard, :historical_source, @default) do
      {module, opts} when is_atom(module) and is_list(opts) ->
        apply(module, function, args ++ [opts])

      module when is_atom(module) ->
        apply(module, function, args ++ [[]])
    end
  end
end

defmodule TimelessTracesDashboard.HistoricalSource.Local do
  @moduledoc false
  @behaviour TimelessTracesDashboard.HistoricalSource

  @impl true
  def query(filters, _opts), do: TimelessTraces.query(filters)

  @impl true
  def trace(trace_id, _opts), do: TimelessTraces.trace(trace_id)
end

defmodule TimelessTracesDashboard.HistoricalSource.DataPlane do
  @moduledoc """
  Historical source backed by the loopback `timeless-traces-api` process.

  The response is converted only after the complete body passes structural and
  rich-span validation, so a failure never exposes a partial result to LiveView.
  """

  @behaviour TimelessTracesDashboard.HistoricalSource

  alias TimelessTracesDashboard.DataPlane.Client

  @impl true
  def query(filters, opts) do
    client = Keyword.get(opts, :client, Client)
    client.search(filters, Keyword.get(opts, :client_opts, []))
  end

  @impl true
  def trace(trace_id, opts) do
    client = Keyword.get(opts, :client, Client)
    client.trace(trace_id, Keyword.get(opts, :client_opts, []))
  end
end
