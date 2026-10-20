defmodule Omunculus.Git do
  @moduledoc "Runs git on the harness side, outside the sandbox, with no user or system configuration."

  @spec run([String.t()], String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, pos_integer, String.t()}
  def run(args, cd, env \\ []) do
    case System.cmd("git", args,
           env:
             env ++
               [
                 {"GIT_CONFIG_NOSYSTEM", "1"},
                 {"GIT_CONFIG_GLOBAL", "/dev/null"},
                 {"GIT_OPTIONAL_LOCKS", "0"}
               ],
           cd: cd,
           stderr_to_stdout: true
         ) do
      {said, 0} -> {:ok, said}
      {said, status} -> {:error, status, said}
    end
  end
end
