defmodule Omunculus.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Attachments

  setup do
    dir = Path.join(System.tmp_dir!(), "attachments-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{store: %{attachments: dir, attachment_bytes: 16}, dir: dir}
  end

  test "keeps a file once under its sha256 and describes it", %{store: store, dir: dir} do
    assert {:ok, meta} = Attachments.put(store, "notes.txt", "text/plain", "hello")

    assert meta == %{
             "name" => "notes.txt",
             "media_type" => "text/plain",
             "bytes" => 5,
             "sha256" => "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
           }

    assert {:ok, ^meta} = Attachments.put(store, "notes.txt", "text/plain", "hello")
    assert File.ls!(dir) == [meta["sha256"]]
    assert {:ok, path} = Attachments.path(store, meta["sha256"])
    assert File.read!(path) == "hello"
  end

  test "refuses a file past attachment_bytes, a name with a directory and a bad media type",
       %{store: store} do
    assert {:error, {:attachment, {:too_large, 17, 16}}} =
             Attachments.put(
               store,
               "big.bin",
               "application/octet-stream",
               String.duplicate("x", 17)
             )

    assert {:error, {:attachment, {:invalid, :name}}} =
             Attachments.put(store, "../etc/passwd", "text/plain", "x")

    assert {:error, {:attachment, {:invalid, :media_type}}} =
             Attachments.put(store, "a.txt", "text", "x")
  end

  test "checks a description against the file kept for it", %{store: store} do
    {:ok, meta} = Attachments.put(store, "a.txt", "text/plain", "abc")
    assert {:ok, [^meta]} = Attachments.check(store, [meta])

    sha = meta["sha256"]

    assert {:error, {:attachment, {:mismatch, ^sha}}} =
             Attachments.check(store, [%{meta | "bytes" => 4}])

    assert {:error, {:attachment, :not_found}} =
             Attachments.check(store, [%{meta | "sha256" => String.duplicate("0", 64)}])

    assert {:error, {:attachment, :invalid}} = Attachments.check(store, [%{"name" => "a.txt"}])
  end

  test "without [store] attachments nothing is kept" do
    store = %{attachments: nil, attachment_bytes: nil}

    assert {:error, {:attachment, :not_configured}} =
             Attachments.put(store, "a", "text/plain", "x")

    assert {:error, {:attachment, :not_configured}} = Attachments.check(store, [])
  end
end
