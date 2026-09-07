defmodule Omunculus.Harness do
  @moduledoc false

  import ExUnit.Assertions, only: [flunk: 1]

  alias Omunculus.Config
  alias Omunculus.EventCore

  def fixtures_dir do
    Path.expand("../fixtures/config", __DIR__)
  end

  def await_log(core, fun, timeout \\ 5_000) when is_function(fun, 1) do
    case find_match(core, fun) do
      {:ok, env} ->
        env

      :not_found ->
        try do
          :ok = EventCore.subscribe(core)

          case find_match(core, fun) do
            {:ok, env} -> env
            :not_found -> receive_match(core, fun, timeout)
          end
        after
          EventCore.unsubscribe(core)
        end
    end
  end

  def tmp_fixture(base, overlay \\ nil) do
    dir = Path.join(System.tmp_dir!(), "omunculus-harness-#{System.unique_integer([:positive])}")
    :ok = File.mkdir_p!(dir)

    src = Path.join(fixtures_dir(), base)
    dest = Path.join(dir, "omunculus.toml")
    :ok = File.cp!(src, dest)

    overlay_path =
      if overlay do
        overlay_src = Path.join(fixtures_dir(), overlay)
        overlay_dest = Path.join(dir, Path.basename(overlay))
        :ok = File.cp!(overlay_src, overlay_dest)
        overlay_dest
      end

    config_file = overlay_path || dest

    {:ok, config} = Config.load(cwd: dir, config_file: config_file, env: %{})

    %{dir: dir, path: dest, config: config, overlay_path: overlay_path}
  end

  defp find_match(core, fun) do
    case Enum.find(EventCore.stream(core, 0), fun) do
      nil -> :not_found
      env -> {:ok, env}
    end
  end

  defp receive_match(core, fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_match(core, fun, deadline, timeout)
  end

  defp do_receive_match(core, fun, deadline, total_timeout) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("await_log timed out after #{total_timeout}ms with no matching envelope")
    else
      receive do
        {:event_core, env} ->
          if fun.(env) do
            env
          else
            do_receive_match(core, fun, deadline, total_timeout)
          end
      after
        remaining ->
          left = max(deadline - System.monotonic_time(:millisecond), 0)

          flunk(
            "await_log timed out after #{total_timeout}ms (#{left}ms remaining) with no matching envelope"
          )
      end
    end
  end
end
