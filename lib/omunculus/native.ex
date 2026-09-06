defmodule Omunculus.Native do
  @moduledoc """
  Makes the SQLite NIF loadable from the escript.

  An escript cannot serve `priv/` files from inside its archive, so
  `:code.priv_dir(:exqlite)` fails and the NIF never loads. At build time we
  embed the compiled shared object; at startup we extract it once to a cache
  directory laid out as `<cache>/exqlite/{ebin,priv}` and prepend that `ebin`
  to the code path so `:code.lib_dir(:exqlite)` resolves to the cache.
  """

  @nif_name "sqlite3_nif.so"
  @nif_source Path.join(:code.priv_dir(:exqlite), @nif_name)
  @external_resource @nif_source
  @nif_binary File.read!(@nif_source)
  @nif_hash :crypto.hash(:sha256, @nif_binary) |> Base.encode16(case: :lower)

  def ensure_nif! do
    case :code.priv_dir(:exqlite) do
      dir when is_list(dir) ->
        if File.exists?(Path.join(dir, @nif_name)), do: :ok, else: extract!()

      {:error, _} ->
        extract!()
    end
  end

  defp extract! do
    root = Path.join([cache_dir(), "exqlite-" <> String.slice(@nif_hash, 0, 16)])
    priv = Path.join(root, "priv")
    ebin = Path.join(root, "ebin")
    target = Path.join(priv, @nif_name)

    File.mkdir_p!(priv)
    File.mkdir_p!(ebin)

    unless File.exists?(target) do
      tmp = target <> ".#{System.unique_integer([:positive])}.tmp"
      File.write!(tmp, @nif_binary)
      File.chmod!(tmp, 0o755)
      File.rename!(tmp, target)
    end

    # `:code.lib_dir/1` derives the app root from the `ebin` entry on the path;
    # the real ebin inside the archive is not a filesystem directory.
    true = :code.add_patha(String.to_charlist(ebin))
    :ok
  end

  defp cache_dir do
    base =
      System.get_env("XDG_CACHE_HOME") ||
        Path.join(System.get_env("HOME") || System.tmp_dir!(), ".cache")

    Path.join(base, "omunculus")
  end
end
