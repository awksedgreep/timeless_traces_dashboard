defmodule TimelessTracesDashboard.HistoricalSource do
  @moduledoc """
  Configurable owner boundary for dashboard reads and live-tail subscription.

  The local source preserves the embedded-library behavior. The data-plane
  source delegates all available reads to one configured Rust HTTP client and
  rejects live tail explicitly; it never falls back to `TimelessTraces`.
  """

  @callback query(keyword(), keyword()) ::
              {:ok, TimelessTraces.Result.t()} | {:error, term()}
  @callback trace(String.t(), keyword()) ::
              {:ok, [TimelessTraces.Span.t()]} | {:error, term()}
  @callback stats(keyword()) :: {:ok, map()} | {:error, term()}
  @callback subscribe(keyword()) :: :ok | {:error, term()}
  @callback unsubscribe(keyword()) :: :ok | {:error, term()}

  @default TimelessTracesDashboard.HistoricalSource.Local

  def query(filters), do: call(:query, [filters])
  def trace(trace_id), do: call(:trace, [trace_id])
  def stats, do: call(:stats, [])
  def subscribe, do: call(:subscribe, [])
  def unsubscribe, do: call(:unsubscribe, [])

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

  @impl true
  def stats(_opts), do: TimelessTraces.stats()

  # TimelessTraces.subscribe/1 delegates straight to Registry.register/3, which
  # answers {:ok, pid} — never a bare :ok. Returning that unchanged breaks the
  # `:ok | {:error, term()}` contract this module declares, and callers that
  # match the contract crash with a CaseClauseError on the success path. The
  # live tail LiveView died during mount and the page hung.
  #
  # Already being registered also means the caller will receive spans, so it is
  # success rather than an error.
  @impl true
  def subscribe(_opts) do
    case TimelessTraces.subscribe() do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Registry.unregister/2 always answers :ok, so there is no failure to map.
  @impl true
  def unsubscribe(_opts), do: TimelessTraces.unsubscribe()
end

defmodule TimelessTracesDashboard.HistoricalSource.DataPlane do
  @moduledoc """
  Historical source backed by the loopback `timeless-traces-api` process.

  The response is converted only after the complete body passes structural and
  rich-span validation, so a failure never exposes a partial result to LiveView.
  """

  @behaviour TimelessTracesDashboard.HistoricalSource

  @impl true
  def query(filters, opts), do: invoke(opts, :search, [filters])

  @impl true
  def trace(trace_id, opts), do: invoke(opts, :trace, [trace_id])

  @impl true
  def stats(opts) do
    with {:ok, stats} <- invoke(opts, :stats, []) do
      {:ok, normalize_stats(stats)}
    end
  end

  @impl true
  def subscribe(_opts), do: {:error, {:unsupported_capability, :traces_live_tail}}

  @impl true
  def unsubscribe(_opts), do: {:error, {:unsupported_capability, :traces_live_tail}}

  defp invoke(opts, function, args) do
    with {:ok, client} <- Keyword.fetch(opts, :client) do
      client_opts = Keyword.get(opts, :client_opts, [])

      # function_exported?/3 never loads the module, and outside embedded
      # mode (mix dev/test) it may not be loaded yet — without this, a
      # perfectly valid client is reported as invalid.
      Code.ensure_loaded(client)

      cond do
        client_opts != [] and function_exported?(client, function, length(args) + 1) ->
          apply(client, function, args ++ [client_opts])

        function_exported?(client, function, length(args)) ->
          apply(client, function, args)

        function_exported?(client, function, length(args) + 1) ->
          apply(client, function, args ++ [[]])

        true ->
          {:error, {:invalid_data_plane_client, client, function}}
      end
    else
      :error -> {:error, :missing_data_plane_client}
    end
  end

  defp normalize_stats(stats) when is_map(stats) do
    total_bytes = value(stats, :bytes_on_disk, value(stats, :total_bytes, 0))

    %{
      total_entries: value(stats, :total_spans, value(stats, :total_entries, 0)),
      total_bytes: total_bytes,
      raw_blocks: value(stats, :raw_blocks, 0),
      raw_bytes: value(stats, :raw_bytes, 0),
      compressed_blocks: value(stats, :compressed_blocks, 0),
      compressed_bytes: value(stats, :compressed_bytes, total_bytes),
      compression_raw_bytes_in: value(stats, :extension_compression_input_bytes_total, 0),
      compression_compressed_bytes_out:
        value(stats, :extension_compression_output_bytes_total, 0),
      # Engine-persisted logical-span bytes (ids + kind/status + timings + all
      # string fields), counted once when spans become durable. Monotonic under
      # optimize/prune, restart-safe. Unlike the codec totals above, this key is
      # served without the extension_ prefix. 0 on pre-upgrade servers/databases.
      raw_ingested_bytes: value(stats, :raw_ingested_bytes_total, 0),
      compaction_count: value(stats, :extension_optimize_count, 0),
      oldest_timestamp: value(stats, :oldest_timestamp_nanoseconds, nil),
      newest_timestamp: value(stats, :newest_timestamp_nanoseconds, nil),
      storage_mode: :libsql
    }
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
