defmodule Omunculus.MediaTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Config, ExecutionPolicyFixtures, Fixtures, Harness, Media, Project}
  alias Omunculus.Store.Query
  alias Omunculus.Tools.Out

  test "names an image or a PDF by its first bytes, and nothing else" do
    assert Media.type(Fixtures.png()) == "image/png"
    assert Media.type(<<0xFF, 0xD8, 0xFF, 0xE0, 0>>) == "image/jpeg"
    assert Media.type("GIF89a") == "image/gif"
    assert Media.type("RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 ") == "image/webp"
    assert Media.type("%PDF-1.7") == "application/pdf"
    assert Media.type("RIFF" <> <<0, 0, 0, 0>> <> "WAVEfmt ") == nil
    assert Media.type("plain text") == nil
  end

  describe "a tool that shows media" do
    setup do
      dir = Fixtures.tmp_dir()
      Fixtures.install_default(dir)
      path = Fixtures.config_path(dir)

      data =
        path
        |> Toml.decode_file!()
        |> put_in(["store", "attachments"], Path.join(dir, "files"))
        |> put_in(["store", "attachment_bytes"], 4096)
        |> put_in(["policy", "media_bytes"], 100)

      File.write!(path, Config.Toml.encode(data))
      %{dir: dir}
    end

    defp shows(dir, part) do
      Fixtures.write_model_tool(
        dir,
        "shower",
        Jason.encode!(%{ok: true, output: "here", emit: [], media: [part]})
      )

      project = Fixtures.open_project(dir)
      work_id = Fixtures.insert(project.conn, :works)
      run_id = Fixtures.insert(project.conn, :runs, %{work_id: work_id})

      ctx = %{
        trigger: "model",
        run_id: run_id,
        author: "agent",
        agent: "concierge",
        execution: ExecutionPolicyFixtures.policy(dir, network: "host")
      }

      result = Harness.dispatch(project, "shower", %{}, ctx)

      {:ok, [event]} =
        Query.all(project.conn, "SELECT body FROM events WHERE type = 'tool' AND run_id = ?", [
          run_id
        ])

      Project.close(project)
      {result, event.body}
    end

    test "keeps the bytes once and records a reference, not the base64", %{dir: dir} do
      data = Base.encode64(Fixtures.png())
      part = %{media_type: "image/png", name: "page.png", data: data}

      assert {{:ok, %{media: [ref]}, _events}, body} = shows(dir, part)

      assert %{"name" => "page.png", "media_type" => "image/png", "sha256" => sha256} = ref
      assert ref["bytes"] == byte_size(Fixtures.png())
      assert File.read!(Path.join([dir, "files", sha256])) == Fixtures.png()

      assert %{"media" => [^ref], "output" => "here"} = Jason.decode!(body)
      refute body =~ data
    end

    test "says in the output what is over media_bytes", %{dir: dir} do
      part = %{
        media_type: "image/png",
        name: "big.png",
        data: Base.encode64(:binary.copy("x", 300))
      }

      assert {{:ok, %{media: [], output: output}, _events}, body} = shows(dir, part)
      assert output == "here\n" <> Out.media_refused("big.png", Out.media_too_large(300, 100))
      refute Jason.decode!(body) |> Map.has_key?("media")
    end

    test "refuses a path outside the workspace", %{dir: dir} do
      part = %{media_type: "image/png", path: "/etc/hostname"}

      assert {{:ok, %{media: [], output: output}, _events}, _body} = shows(dir, part)
      assert output =~ "hostname is not shown: path outside roots"
    end
  end

  describe "result/3 and render/2" do
    setup do
      dir = Fixtures.tmp_dir()
      store = %{attachments: dir, attachment_bytes: 4096}
      {:ok, png} = Omunculus.Attachments.put(store, "a.png", "image/png", Fixtures.png())
      {:ok, pdf} = Omunculus.Attachments.put(store, "b.pdf", "application/pdf", "%PDF-1.4")
      %{store: store, refs: [png, pdf]}
    end

    test "is the text alone without media", %{store: store} do
      assert Media.result(store, "text", []) == "text"
      assert Media.render("text", nil) == {"text", []}
    end

    test "encodes what the model takes and names the rest", %{store: store, refs: refs} do
      result = Media.result(store, "read", refs)

      assert {"read", [%{"media_type" => "image/png", "data" => data}, %{"name" => "b.pdf"}]} =
               Media.render(result, nil)

      assert Base.decode64!(data) == Fixtures.png()

      assert {text, [%{"name" => "a.png"}]} = Media.render(result, ["image/png"])

      assert text ==
               "read\n" <>
                 Out.media_refused("b.pdf", Out.media_not_taken("application/pdf", ["image/png"]))
    end

    test "a call in code mode gets the text and the count", %{store: store, refs: refs} do
      assert {:ok, text} = Media.text_only({:ok, Media.result(store, "read", refs)})
      assert text == "read\n" <> Out.media_text_only(2)
      assert Media.text_only({:ok, "plain"}) == {:ok, "plain"}
    end
  end
end
