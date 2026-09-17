cargo_exclusions = if System.find_executable("cargo"), do: [], else: [:cargo]

Application.put_env(
  :omunculus,
  :package_tools,
  Application.app_dir(:omunculus, Path.join("priv", "tools"))
)

ExUnit.start(exclude: [:local_model] ++ cargo_exclusions)
