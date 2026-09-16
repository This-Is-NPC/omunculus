defmodule Omunculus.SandboxTest do
  use ExUnit.Case, async: true
  alias Omunculus.Sandbox

  test "JavaScript calls simple and composite tools through the same bridge" do
    call = fn
      "read", %{"path" => "x"} -> {:ok, "file"}
      "compact", %{"op" => "load"} -> {:ok, "comments"}
      "compact", %{"op" => "commit", "summary" => "comments summarized"} -> {:ok, "saved"}
    end

    code = """
    const [file, comments] = await Promise.all([tools.read({path: 'x'}), tools.compact({op: 'load'})]);
    const saved = await tools.compact({op: 'commit', summary: comments + ' summarized'});
    return file + ':' + saved;
    """

    assert {:ok, "file:saved"} = Sandbox.run(code, [%{name: "read"}, %{name: "compact"}], call)
  end

  test "missing names cannot bypass the bridge's authorized catalog" do
    code =
      ~S|Deno.stdout.writeSync(new TextEncoder().encode(JSON.stringify({type:'call',id:1,name:'forbidden',args:{}})+'\n')); await new Promise(() => {});|

    assert {:error, _} =
             Sandbox.run(code, [], fn _, _ -> flunk("must not call forbidden tool") end,
               timeout: 200
             )
  end

  for {capability, code} <- [
        {"read", "return await Deno.readTextFile('/etc/passwd')"},
        {"write", "return await Deno.writeTextFile('/tmp/omunculus-sandbox-forbidden', 'x')"},
        {"environment", "return Deno.env.get('HOME')"},
        {"network", "return await fetch('http://127.0.0.1:8765')"},
        {"process", "return await new Deno.Command('sh', {args: ['-c', 'true']}).output()"}
      ] do
    test "denies direct #{capability} access" do
      assert {:error, {:javascript, error}} =
               Sandbox.run(unquote(code), [], fn _, _ -> flunk("no tools") end)

      assert error =~ "NotCapable"
    end
  end

  test "a non-terminating program is stopped" do
    assert {:error, :sandbox_timeout} =
             Sandbox.run("while (true) {}", [], fn _, _ -> :unused end, timeout: 200)
  end

  test "terminal tool actions propagate out and stop the sandbox" do
    assert catch_throw(
             Sandbox.run("await tools.continue({});", [%{name: "continue"}], fn _, _ ->
               throw(:run_ended)
             end)
           ) == :run_ended
  end
end
