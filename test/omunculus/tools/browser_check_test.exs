defmodule Omunculus.Tools.BrowserCheckTest do
  use ExUnit.Case, async: true

  @moduletag :sandbox
  @moduletag timeout: 120_000

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.{Invoke, Manifest}

  @tool Path.expand("priv/tools/browser_check")

  @index """
  <!doctype html><title>Fixture</title><h1>Hello fixture</h1>
  <a href="/about.html">About</a><input id="name">
  <button id="go" onclick="document.getElementById('out').textContent = 'clicked ' + document.getElementById('name').value">Go</button>
  <p id="out"></p><script>console.error("boom")</script><img src="/missing.png">
  """

  setup do
    root = Omunculus.Fixtures.tmp_dir()
    File.write!(Path.join(root, "index.html"), @index)
    %{root: root}
  end

  defp call(root, args, options) do
    {:ok, manifest} = Manifest.load(Path.join(@tool, "tool.toml"))

    policy = ExecutionPolicyFixtures.policy([root, @tool], [network: "none"] ++ options)

    policy = %{
      policy
      | environment: %{"HOME" => "/tmp/home", "PATH" => "/usr/bin"},
        limits: %{policy.limits | timeout_ms: 90_000, max_output_bytes: 100_000}
    }

    input = %{name: "browser_check", args: args, view: %{}, roots: [root]}
    assert {:ok, out} = Invoke.call(manifest, input, policy)
    out
  end

  defp args(port, extra \\ %{}) do
    Map.merge(
      %{
        "port" => port,
        "command" => "python3 -m http.server #{port} --bind 127.0.0.1",
        "viewports" => ["1440x900", "390x844"]
      },
      extra
    )
  end

  test "loads the page at each viewport inside the sandbox, with no network grant", %{root: root} do
    steps = [
      %{"action" => "fill", "selector" => "#name", "value" => "ana"},
      %{"action" => "click", "selector" => "#go"},
      %{"action" => "expect_text", "text" => "clicked ana"}
    ]

    out =
      call(
        root,
        args(48_731, %{"steps" => steps}),
        read_only: [@tool],
        read_write: [root]
      )

    assert out.ok, out.output
    assert out.output =~ "## / at 1440x900"
    assert out.output =~ "## / at 390x844"
    assert out.output =~ "status: 200"
    assert out.output =~ "title: Fixture"
    assert out.output =~ "- h1 Hello fixture"
    assert out.output =~ "- About -> /about.html"
    assert out.output =~ "- Go"
    assert out.output =~ "- boom"
    assert out.output =~ "404 http://127.0.0.1:48731/missing.png"

    for size <- ["1440x900", "390x844"] do
      assert <<0x89, "PNG", _::binary>> =
               File.read!(Path.join(root, ".browser_check/index-#{size}.png"))
    end

    # Each screenshot is shown to the model, saved or not.
    assert [%{"name" => "index-1440x900.png", "data" => data}, %{"name" => "index-390x844.png"}] =
             out.media

    assert <<0x89, "PNG", _::binary>> = Base.decode64!(data)

    # The dev server stopped with the call.
    assert {:error, _} = :gen_tcp.connect(~c"127.0.0.1", 48_731, [], 200)
  end

  test "loads the page by the host name it is given", %{root: root} do
    out =
      call(root, args(48_735, %{"host" => "fixture.localhost", "viewports" => ["800x600"]}),
        read_only: [@tool],
        read_write: [root]
      )

    assert out.ok, out.output
    assert out.output =~ "title: Fixture"
    assert out.output =~ "404 http://fixture.localhost:48735/missing.png"
  end

  test "a step that fails fails the call and says which", %{root: root} do
    steps = [%{"action" => "expect_text", "text" => "not there"}]

    out =
      call(root, args(48_732, %{"steps" => steps, "viewports" => ["800x600"]}),
        read_only: [@tool],
        read_write: [root]
      )

    refute out.ok
    assert out.output =~ "(FAILED)"
    assert out.output =~ ~s(expect_text "not there": not on the page)
  end

  test "a missing path reports its status", %{root: root} do
    out =
      call(root, args(48_733, %{"paths" => ["/nope"], "viewports" => ["800x600"]}),
        read_only: [@tool],
        read_write: [root]
      )

    refute out.ok
    assert out.output =~ "status: 404"
  end

  test "a read-only workspace still reports, without a screenshot", %{root: root} do
    out =
      call(root, args(48_734, %{"viewports" => ["800x600"]}),
        read_only: [root, @tool],
        read_write: []
      )

    assert out.ok, out.output
    assert out.output =~ "screenshot: not saved"
  end
end
