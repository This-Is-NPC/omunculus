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
end
