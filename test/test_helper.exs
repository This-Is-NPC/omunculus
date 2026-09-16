cargo_exclusions = if System.find_executable("cargo"), do: [], else: [:cargo]

ExUnit.start(exclude: [:local_model] ++ cargo_exclusions)
