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
end
