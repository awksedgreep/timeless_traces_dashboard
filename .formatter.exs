[
  import_deps: [:phoenix_live_view],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  export: [
    locals_without_parens: [timeless_traces_dashboard: 1, timeless_traces_dashboard: 2]
  ]
]
