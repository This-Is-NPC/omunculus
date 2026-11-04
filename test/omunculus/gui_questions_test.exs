defmodule Omunculus.GuiQuestionsTest do
  use ExUnit.Case, async: true

  test "numbered questions parse into items and join into one reply" do
    script = """
    const text = "I need a few things:\\n1. Which colours?\\n   (brand or new)\\n2. Which sites do you like?\\n3) Any deadline?";
    const form = Questions.parse(text);
    if (form.intro !== "I need a few things:") throw Error("intro " + form.intro);
    if (form.items.length !== 3 || form.items[0].text !== "Which colours?\\n   (brand or new)" || form.items[2].n !== 3 || form.items[2].text !== "Any deadline?")
      throw Error(JSON.stringify(form));
    if (Questions.parse("Just one?\\n1. Only this") !== null) throw Error("single item");
    if (Questions.parse("No list here") !== null || Questions.parse("") !== null) throw Error("plain");
    if (Questions.parse("1. a\\n3. b") !== null) throw Error("sequence must count from 1");
    const joined = Questions.join(form.items, ["red", "I don't know yet\\nsorry", ""]);
    if (joined !== "1. red\\n2. I don't know yet\\n   sorry\\n3. ") throw Error(JSON.stringify(joined));
    """

    assert {"", 0} = Omunculus.GuiModules.run(["Questions"], script)
  end
end
