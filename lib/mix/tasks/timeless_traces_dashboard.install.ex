if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.TimelessTracesDashboard.Install do
    @shortdoc "Installs TimelessTracesDashboard into your application."
    @moduledoc """
    #{@shortdoc}

    Configures TimelessTraces app environment, sets up the OpenTelemetry exporter,
    configures your Phoenix router with the traces dashboard page, and updates
    the formatter.

    ## Usage

        mix igniter.install timeless_traces_dashboard
        mix igniter.install timeless_traces_dashboard --storage memory

    ## Options

      * `--storage` — `disk` (default) or `memory`. Memory mode stores traces
        in memory only (lost on restart).

    ## What it does

    1. Adds `config :timeless_traces, data_dir: "priv/timeless_traces"` to `config.exs`
    2. Adds `config :opentelemetry, traces_exporter: {TimelessTraces.Exporter, []}` to `config.exs`
    3. Adds `import TimelessTracesDashboard.Router` to your Phoenix router
    4. Adds `timeless_traces_dashboard "/dashboard"` to your router's browser scope
    5. Adds `:timeless_traces_dashboard` to your `.formatter.exs` import_deps
    6. Reminds you to remove the default LiveDashboard route (avoids live_session conflict)
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :timeless_traces_dashboard,
        schema: [storage: :string],
        defaults: [storage: "disk"],
        required: [],
        positional: [],
        aliases: [],
        composes: [],
        installs: [],
        adds_deps: [],
        example: "mix igniter.install timeless_traces_dashboard --storage memory"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      storage = igniter.args.options[:storage] || "disk"

      igniter
      |> configure_timeless_traces(storage)
      |> configure_opentelemetry()
      |> setup_router()
      |> Igniter.Project.Formatter.import_dep(:timeless_traces_dashboard)
      |> add_live_dashboard_notice()
    end

    defp configure_timeless_traces(igniter, storage) do
      igniter =
        Igniter.Project.Config.configure(
          igniter,
          "config.exs",
          :timeless_traces,
          [:data_dir],
          "priv/timeless_traces"
        )

      case storage do
        "memory" ->
          Igniter.Project.Config.configure(
            igniter,
            "config.exs",
            :timeless_traces,
            [:storage],
            :memory
          )

        _ ->
          igniter
      end
    end

    defp configure_opentelemetry(igniter) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        :opentelemetry,
        [:traces_exporter],
        {:code, Sourceror.parse_string!("{TimelessTraces.Exporter, []}")}
      )
    end

    defp setup_router(igniter) do
      case Igniter.Libs.Phoenix.select_router(igniter) do
        {igniter, nil} ->
          Igniter.add_warning(igniter, """
          No Phoenix router found. Add the following manually:

              import TimelessTracesDashboard.Router

              scope "/" do
                pipe_through :browser
                timeless_traces_dashboard "/dashboard"
              end
          """)

        {igniter, router} ->
          igniter
          |> add_router_import(router)
          |> Igniter.Libs.Phoenix.append_to_scope(
            "/",
            """
            timeless_traces_dashboard "/dashboard"
            """,
            with_pipelines: [:browser],
            router: router
          )
      end
    end

    defp add_router_import(igniter, router) do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        case Igniter.Libs.Phoenix.move_to_router_use(igniter, zipper) do
          {:ok, zipper} ->
            {:ok, Igniter.Code.Common.add_code(zipper, "import TimelessTracesDashboard.Router")}

          _ ->
            {:ok, zipper}
        end
      end)
    end

    defp add_live_dashboard_notice(igniter) do
      Igniter.add_notice(igniter, """
      TimelessTracesDashboard installs its own LiveDashboard at /dashboard.

      If your router has a default LiveDashboard route (typically in a
      `if Application.compile_env(:your_app, :dev_routes)` block), you should
      remove it to avoid a live_session conflict.
      """)
    end
  end
else
  defmodule Mix.Tasks.TimelessTracesDashboard.Install do
    @shortdoc "Installs TimelessTracesDashboard (requires igniter)."
    @moduledoc @shortdoc
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'timeless_traces_dashboard.install' requires igniter.
      Please install igniter and try again.

          {:igniter, "~> 0.6", only: [:dev]}

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
