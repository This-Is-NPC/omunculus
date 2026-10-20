defmodule Omunculus.Tools.Omapass do
  @moduledoc """
  Builtin `omapass` tool: what a client needs to take a provider's key
  from omapass, the optional Omarchy password plugin over gnome-keyring.
  Prints `installed`; once it is, `program`, the path a `!` key runs, and
  `accounts`, each password it keeps (`account`, `folder`) but not its
  Nostr keys and never a secret; and `error` when it could not list them.
  The program is `omapass` on `PATH`, or where Omarchy installs the
  plugin under `HOME`. It runs in the harness's process, as a `!` key does: the
  keyring answers only outside the sandbox.
  """

  alias Omunculus.Tools.Out

  @plugin ".config/omarchy/plugins/io.github.this-is-npc.omapass/bin/omapass"

  @spec run(map) :: map
  def run(_input) do
    case program() do
      nil ->
        Out.ok(Jason.encode!(%{installed: false}))

      program ->
        Out.ok(Jason.encode!(Map.merge(%{installed: true, program: program}, list(program))))
    end
  end

  defp program do
    plugin = System.get_env("HOME") && Path.join(System.get_env("HOME"), @plugin)
    System.find_executable("omapass") || if(plugin && File.regular?(plugin), do: plugin)
  end

  defp list(program) do
    case System.cmd(program, ["list", "--json"]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, items} when is_list(items) -> %{accounts: accounts(items)}
          _invalid -> %{accounts: [], error: "omapass list printed no JSON list"}
        end

      {_output, status} ->
        %{accounts: [], error: "omapass list exited with #{status}"}
    end
  end

  defp accounts(items) do
    for %{"account" => account} = item <- items, item["kind"] in [nil, ""] do
      %{account: account, folder: item["folder"] || ""}
    end
    |> Enum.sort_by(& &1.account)
  end
end
