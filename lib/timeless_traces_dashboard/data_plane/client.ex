defmodule TimelessTracesDashboard.DataPlane.Client do
  @moduledoc """
  Complete-response client for the native traces dashboard API.

  The adapter owns no storage connection. It buffers one bounded HTTP response,
  decodes it once, validates every returned span, and publishes either the
  complete operation or one error.
  """

  alias TimelessTracesDashboard.DataPlane.Process, as: DataPlaneProcess

  @default_timeout 30_000
  @kinds %{
    "internal" => :internal,
    "server" => :server,
    "client" => :client,
    "producer" => :producer,
    "consumer" => :consumer
  }
  @statuses %{"unset" => :unset, "ok" => :ok, "error" => :error}

  @spec search(keyword(), keyword()) ::
          {:ok, TimelessTraces.Result.t()} | {:error, term()}
  def search(filters, opts \\ []) when is_list(filters) do
    params =
      filters
      |> Keyword.take([:name, :service, :kind, :status, :since, :until, :limit, :offset, :order])
      |> Map.new(fn {key, value} -> {key, encode_param(value)} end)

    with {:ok, body} <- get_json("/select/timeless/api/spans", params, opts),
         {:ok, result} <- decode_search(body) do
      {:ok, result}
    end
  end

  @spec trace(String.t(), keyword()) ::
          {:ok, [TimelessTraces.Span.t()]} | {:error, term()}
  def trace(trace_id, opts \\ []) when is_binary(trace_id) do
    with true <- valid_id?(trace_id, 32) || {:error, :invalid_trace_id},
         {:ok, body} <- get_json("/select/timeless/api/traces/#{trace_id}", %{}, opts),
         %{"spans" => spans} when is_list(spans) <- body,
         {:ok, spans} <- decode_spans(spans),
         true <- Enum.all?(spans, &(&1.trace_id == trace_id)) || {:error, :trace_id_mismatch} do
      {:ok, spans}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_trace_response}
    end
  end

  @spec stats(keyword()) :: {:ok, map()} | {:error, term()}
  def stats(opts \\ []), do: get_json("/select/traces/stats", %{}, opts)

  @doc false
  def request_json(path, params, opts \\ []), do: get_json(path, params, opts)

  defp get_json(path, params, opts) do
    with {:ok, status, body} <- raw_request(path, params, opts),
         true <- status in 200..299 || {:error, {:unexpected_response, status, excerpt(body)}},
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_response, error}}
      {:error, _reason} = error -> error
    end
  end

  defp raw_request(path, params, opts) do
    with {:ok, endpoint} <- resolve_endpoint(opts) do
      request_options = [
        method: :get,
        url: endpoint <> path,
        params: params,
        headers: Keyword.get(opts, :headers, []),
        receive_timeout: Keyword.get(opts, :timeout, @default_timeout),
        retry: false,
        decode_body: false
      ]

      request = Keyword.get(opts, :request, &Req.request/1)

      case request.(request_options) do
        {:ok, %Req.Response{status: status, body: body}} when is_binary(body) ->
          {:ok, status, body}

        {:ok, %{status: status, body: body}} when is_integer(status) and is_binary(body) ->
          {:ok, status, body}

        {:ok, %{status: status, body: body}} ->
          {:error, {:invalid_response_body, status, body}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  rescue
    error -> {:error, {:transport, error}}
  catch
    :exit, reason -> {:error, {:transport, reason}}
  end

  defp resolve_endpoint(opts) do
    case Keyword.fetch(opts, :base_url) do
      {:ok, endpoint} when is_binary(endpoint) ->
        loopback_endpoint(endpoint)

      _ ->
        process = Keyword.get(opts, :process, DataPlaneProcess)
        timeout = Keyword.get(opts, :timeout, @default_timeout)

        case DataPlaneProcess.await_ready(process, timeout) do
          {:ok, endpoint} -> loopback_endpoint(endpoint)
          {:error, _reason} = error -> error
        end
    end
  end

  defp loopback_endpoint(endpoint) do
    uri = URI.parse(endpoint)

    with "http" <- uri.scheme,
         host when is_binary(host) <- uri.host,
         {:ok, address} <- :inet.parse_address(String.to_charlist(host)),
         true <- loopback_address?(address),
         true <- uri.userinfo == nil and uri.query == nil and uri.fragment == nil,
         true <- uri.path in [nil, "", "/"] do
      {:ok, String.trim_trailing(endpoint, "/")}
    else
      _ -> {:error, {:traces_data_plane_must_use_loopback, endpoint}}
    end
  end

  defp loopback_address?({127, _, _, _}), do: true
  defp loopback_address?(_address), do: false

  defp decode_search(%{
         "entries" => entries,
         "total" => total,
         "limit" => limit,
         "offset" => offset,
         "has_more" => has_more
       })
       when is_list(entries) and is_integer(total) and total >= 0 and is_integer(limit) and
              limit > 0 and is_integer(offset) and offset >= 0 and is_boolean(has_more) do
    with true <- length(entries) <= limit || {:error, :response_exceeds_limit},
         {:ok, entries} <- decode_spans(entries) do
      {:ok,
       %TimelessTraces.Result{
         entries: entries,
         total: total,
         limit: limit,
         offset: offset,
         has_more: has_more
       }}
    end
  end

  defp decode_search(_body), do: {:error, :invalid_search_response}

  defp decode_spans(spans) do
    spans
    |> Enum.reduce_while({:ok, []}, fn span, {:ok, decoded} ->
      case decode_span(span) do
        {:ok, span} -> {:cont, {:ok, [span | decoded]}}
        {:error, reason} -> {:halt, {:error, {:invalid_span, reason}}}
      end
    end)
    |> case do
      {:ok, spans} -> {:ok, Enum.reverse(spans)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_span(%{
         "trace_id" => trace_id,
         "span_id" => span_id,
         "parent_span_id" => parent_span_id,
         "name" => name,
         "kind" => kind,
         "start_time" => start_time,
         "end_time" => end_time,
         "duration_ns" => duration_ns,
         "status" => status,
         "status_message" => status_message,
         "attributes" => attributes,
         "events" => events,
         "resource" => resource,
         "instrumentation_scope" => instrumentation_scope
       }) do
    with true <- valid_id?(trace_id, 32) || :trace_id,
         true <- valid_id?(span_id, 16) || :span_id,
         true <- valid_optional_id?(parent_span_id, 16) || :parent_span_id,
         true <- is_binary(name) || :name,
         {:ok, kind} <- Map.fetch(@kinds, kind),
         true <- is_integer(start_time) || :start_time,
         true <- is_integer(end_time) || :end_time,
         true <- (is_integer(duration_ns) and duration_ns >= 0) || :duration_ns,
         true <- end_time - start_time == duration_ns || :inconsistent_duration,
         {:ok, status} <- Map.fetch(@statuses, status),
         true <- (is_nil(status_message) or is_binary(status_message)) || :status_message,
         true <- is_map(attributes) || :attributes,
         true <- (is_list(events) and Enum.all?(events, &is_map/1)) || :events,
         true <- is_map(resource) || :resource,
         true <- is_map(instrumentation_scope) || :instrumentation_scope do
      {:ok,
       %TimelessTraces.Span{
         trace_id: trace_id,
         span_id: span_id,
         parent_span_id: parent_span_id,
         name: name,
         kind: kind,
         start_time: start_time,
         end_time: end_time,
         duration_ns: duration_ns,
         status: status,
         status_message: status_message,
         attributes: attributes,
         events: events,
         resource: resource,
         instrumentation_scope: instrumentation_scope
       }}
    else
      :error -> {:error, :unknown_kind_or_status}
      reason -> {:error, reason}
    end
  end

  defp decode_span(_span), do: {:error, :invalid_shape}

  defp valid_optional_id?(nil, _width), do: true
  defp valid_optional_id?(value, width), do: valid_id?(value, width)

  defp valid_id?(value, width) when is_binary(value) and byte_size(value) == width do
    value =~ ~r/\A[0-9a-f]+\z/
  end

  defp valid_id?(_value, _width), do: false

  defp encode_param(%DateTime{} = value), do: DateTime.to_unix(value, :nanosecond)
  defp encode_param(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_param(value), do: value

  defp excerpt(body) when is_binary(body), do: binary_part(body, 0, min(byte_size(body), 1_024))
end
