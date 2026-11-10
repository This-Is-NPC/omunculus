Code.require_file("../../eval/lib/deploy.ex", __DIR__)

defmodule Omunculus.EvalDeployTest do
  use ExUnit.Case, async: false

  test "mirror stores clean URL pages as indexes and preserves asset and explicit file names" do
    options = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> Req.default_options(options) end)

    site = %{
      "/" =>
        ~s(<a href="/cardapio">Menu</a><a href="/sobre">About</a><a href="/contato.html">Contact</a><link href="/system.css">),
      "/cardapio" => ~s(<p>Cake R$ 85</p><a href="/cardapio">Menu</a>),
      "/sobre" => "<p>Since 2009</p>",
      "/contato.html" => "<p>WhatsApp</p>",
      "/system.css" => "body { color: brown; }"
    }

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "host") == ["bakery.production.localhost"]
      Plug.Conn.send_resp(conn, 200, Map.fetch!(site, conn.request_path))
    end)

    dir = Omunculus.Fixtures.tmp_dir()
    assert :ok = EquivalentExchange.Deploy.mirror("bakery", dir)

    for {url, body} <- site do
      relative =
        case url do
          "/" -> "index.html"
          "/cardapio" -> "cardapio/index.html"
          "/sobre" -> "sobre/index.html"
          path -> String.trim_leading(path, "/")
        end

      assert File.read!(Path.join(dir, relative)) == body
    end

    assert length(Path.wildcard(Path.join(dir, "**/*.html"))) == 4
  end

  test "environment names the sockets by the target of a link under a deep state folder" do
    names = ~w(OMUNCULUS_DEPLOY OMUNCULUS_DEPLOY_PROVIDER OMUNCULUS_HOMOLOGATION_KEY OMUNCULUS_PRODUCTION_KEY)
    saved = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- saved,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    root = Omunculus.Fixtures.tmp_dir()
    target = Path.join(root, "sockets")
    state = Path.join([root | List.duplicate(String.duplicate("deep", 10), 4)] ++ [".state"])
    File.mkdir_p!(target)
    File.mkdir_p!(Path.join(state, "keys"))
    File.ln_s!(target, Path.join(state, "sockets"))

    for instance <- ~w(homologation production) do
      File.write!(Path.join(target, instance <> ".sock"), "")
      File.write!(Path.join([state, "keys", instance]), instance <> " key")
    end

    assert byte_size(Path.join([state, "sockets", "homologation.sock"])) > 107
    assert :ok = EquivalentExchange.Deploy.environment(state)
    assert System.get_env("OMUNCULUS_DEPLOY") == target
    assert System.get_env("OMUNCULUS_DEPLOY_PROVIDER") == "dokku"
    assert System.get_env("OMUNCULUS_PRODUCTION_KEY") == "production key"
  end
end
