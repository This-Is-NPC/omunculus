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

  test "a blank line then an unindented line ends the list into an outro" do
    script = """
    const closing = "Anything you do not have yet, just tell us.\\nOnce we have these, we will prepare the preview.";
    const text = "Hello!\\n\\n1. Which colours?\\n2. Which sites?\\n3. Any deadline?\\n4. Your logo?\\n5. Opening hours?\\n6. A short story of the bakery\\n\\n" + closing;
    const form = Questions.parse(text);
    if (form.items.length !== 6 || form.items[5].text !== "A short story of the bakery") throw Error(JSON.stringify(form));
    if (form.outro !== closing || form.intro !== "Hello!") throw Error(JSON.stringify(form));

    const kept = Questions.parse("1. Colours?\\n\\n   (brand or new)\\n2. Sites?\\n\\n\\tlike these\\n3. Deadline?\\nsoon, please");
    if (kept.items[0].text !== "Colours?\\n\\n   (brand or new)" || kept.items[1].text !== "Sites?\\n\\n\\tlike these") throw Error(JSON.stringify(kept));
    if (kept.items[2].text !== "Deadline?\\nsoon, please" || kept.outro !== "") throw Error(JSON.stringify(kept));

    const plain = Questions.parse("1. a\\n2. b\\n\\n");
    if (plain.outro !== "" || plain.items[1].text !== "b") throw Error(JSON.stringify(plain));
    """

    assert {"", 0} = Omunculus.GuiModules.run(["Questions"], script)
  end
end
