cargo_exclusions = if System.find_executable("cargo"), do: [], else: [:cargo]

Application.put_env(
  :omunculus,
  :package_tools,
  Application.app_dir(:omunculus, Path.join("priv", "tools"))
)

# Commits the harness makes take the identity of its environment.
for {name, value} <- [
      {"GIT_AUTHOR_NAME", "test"},
      {"GIT_AUTHOR_EMAIL", "test@localhost"},
      {"GIT_COMMITTER_NAME", "test"},
      {"GIT_COMMITTER_EMAIL", "test@localhost"}
    ],
    do: System.put_env(name, value)

{:ok, _} = Omunculus.Test.ScriptedModel.start_link()

ExUnit.start(exclude: [:local_model] ++ cargo_exclusions)
