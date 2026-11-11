defmodule Omunculus.GuiMarkdownTest do
  use ExUnit.Case, async: true

  test "images become their alt text outside code, and no image mark is left anywhere" do
    script = """
    const expect = (got, want, what) => { if (got !== want) throw Error(what + ": " + JSON.stringify(got) + " != " + JSON.stringify(want)); };
    expect(Markdown.imageless("see ![a cat](http://x/c.png) here"), "see a cat here", "inline image");
    expect(Markdown.imageless("![logo][ref]"), "logo", "reference image");
    expect(Markdown.imageless("<img src='x.png' alt=\\"the logo\\">"), "the logo", "img tag");
    expect(Markdown.imageless("<img src=x.png>"), "", "img tag without alt");
    expect(Markdown.imageless("`![x](y)`"), "`!\\u200b[x](y)`", "inline code keeps its text, guarded");
    expect(Markdown.imageless("```\\n![x](y)\\n```"), "```\\n!\\u200b[x](y)\\n```", "fenced code keeps its text, guarded");
    expect(Markdown.imageless("[a link](https://a.b)"), "[a link](https://a.b)", "a link stays");
    """

    assert {"", 0} = Omunculus.GuiModules.run(["Markdown"], script)
  end

  test "addresses stay links, non-addresses and code are not linked, code is tinted" do
    script = """
    const expect = (got, want, what) => { if (got !== want) throw Error(what + ": " + JSON.stringify(got) + " != " + JSON.stringify(want)); };
    const l = text => Markdown.linked(text, "#abc", "#def");
    const z = text => text.replace(/([\\/.\\-_?=&])(?!\\/)/g, "$1\\u200b");
    const a = (url, label) => '<a href="' + url + '" style="color:#abc">' + (label || z(url.replace("mailto:", ""))) + "</a>";
    expect(l("(contato@doceana.com.br)").text, "(" + a("mailto:contato@doceana.com.br") + ")", "parenthesised");
    expect(l('"x@y.com"').text, '"' + a("mailto:x@y.com") + '"', "quoted");
    expect(l("e-mail: a@b.org").text, "e-mail: " + a("mailto:a@b.org"), "after a colon");
    expect(l("write to a@b.org.").text, "write to " + a("mailto:a@b.org") + ".", "sentence end");
    expect(l("node@22.23.3").text, "node&#64;22.23.3", "version");
    expect(l("(node@22.23.3)").links.length, 0, "version in parentheses");
    expect(l("@types/node").text, "@types/node", "npm scope");
    expect(l("@types/node").links.length, 0, "npm scope, no link");
    expect(l("`node@1.2`").text, '<span style="background-color:#def">node&#64;1.2</span>', "code tinted, untouched");
    expect(l("`a_b*c`").text, '<span style="background-color:#def">a&#95;b&#42;c</span>', "code marks escaped");
    expect(l("```\\nx@y.com\\n```").links.length, 0, "fence unlinked");
    expect(l("see https://a.b/c.").text, "see " + a("https://a.b/c") + ".", "url");
    expect(l("at http://a-b.localhost:9080/x?y=1").text, 'at <a href="http://a-b.localhost:9080/x?y=1" style="color:#abc">http://\\u200ba-\\u200bb.\\u200blocalhost:9080/\\u200bx?\\u200by=\\u200b1</a>', "address breaks after its separators, never inside the port");
    expect(l("[t](https://a.b)").text, a("https://a.b", "t"), "markdown link");
    expect(l("<https://a.b>").links[0], "https://a.b", "autolink");
    expect(Markdown.plain("a `mise run check` **b** _c_ [d](https://e.f) snake_case"), "a mise run check b c d snake_case", "plain");
    """

    assert {"", 0} = Omunculus.GuiModules.run(["Markdown"], script)
  end
end
