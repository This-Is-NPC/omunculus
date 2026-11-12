defmodule Omunculus.GuiComposersTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const when = at => "10:00";
  const message = (key, mine, at) => ({key, mine, at, text: "Hello", from: {name: "Sales", address: "sales@agency"}, to: {name: "Me", address: "me@agency"}, pending: false, request: ""});
  const thread = {key: "agency/c1", subject: "Menu", with: {name: "Sales", address: "sales@agency", agent: "sales", project: "agency"}, pending: [],
    messages: [message("m1", true, "2026-01-01T10:00:00Z"), message("m2", false, "2026-01-01T10:01:00Z")]};
  const ids = state => state.items.map(item => item.id).join();
  const modes = state => state.items.map(item => item.mode).join();
  const several = () => {
    let s = Composers.empty();
    for (let i = 0; i < 4; i++) s = Composers.open(s, {});
    return s;
  };
  """

  defp run!(assertions) do
    assert {"", 0} =
             GuiModules.run(
               ["Requests", "Model", "Mailbox", "Composers"],
               @fixtures <> assertions
             )
  end

  test "several composers open side by side, the newest active" do
    run!("""
    let s = Composers.open(Composers.empty(), {});
    s = Composers.open(s, {subject: "Hello", kind: "new"});
    if (ids(s) !== "c1,c2" || s.active !== "c2" || modes(s) !== "open,open") throw Error(ids(s) + modes(s));
    const slots = Composers.layout(s, 1200, 20);
    if (slots.map(x => x.shape).join() !== "window,window") throw Error("both are windows");
    if (slots[1].x + slots[1].width !== 1180) throw Error("the newest keeps the right margin");
    if (slots[0].x + slots[0].width >= slots[1].x) throw Error("older shifts left, no overlap");
    """)
  end

  test "minimize, restore, expand and close" do
    run!("""
    let s = several();
    s = Composers.minimize(s, "c4");
    if (modes(s) !== "open,open,open,min" || s.active !== "") throw Error(modes(s));
    s = Composers.activate(s, "c4");
    if (modes(s) !== "open,open,open,open" || s.active !== "c4") throw Error("a tab restores");
    s = Composers.expand(s, "c2");
    if (modes(s) !== "open,full,open,open") throw Error("expanded");
    s = Composers.expand(s, "c3");
    if (modes(s) !== "open,open,full,open") throw Error("one expanded at a time");
    if (Composers.layout(s, 1200, 20).some(x => x.id === "c3")) throw Error("the expanded one is not docked");
    s = Composers.expand(s, "c3");
    if (modes(s) !== "open,open,open,open") throw Error("expand again docks it");
    s = Composers.close(s, "c2");
    if (ids(s) !== "c1,c3,c4") throw Error("closed");
    if (Composers.minimize(s, "nope") !== s) throw Error("unknown ids change nothing");
    """)
  end

  test "a minimized or crowded composer is a tab; the rest shrink to fit" do
    run!("""
    let s = Composers.minimize(several(), "c4");
    let slots = Composers.layout(s, 1200, 20);
    if (slots.map(x => x.shape).join() !== "window,window,window,tab") throw Error("minimized is a tab: " + slots.map(x => x.shape));
    slots = Composers.layout(several(), 800, 20);
    const shapes = slots.map(x => x.shape).join();
    if (shapes !== "tab,tab,tab,window") throw Error("older ones collapse when there is no room: " + shapes);
    if (slots[0].x < 20 || slots[3].x + slots[3].width !== 780) throw Error("inside the margins");
    let many = Composers.empty();
    for (let i = 0; i < 6; i++) many = Composers.open(many, {});
    slots = Composers.layout(many, 720, 20);
    if (slots[0].x < 20) throw Error("every tab fits: " + slots[0].x);
    """)
  end

  test "a reply opens for the thread, prefilled" do
    run!("""
    const preset = Composers.replying(thread, "", false, when);
    if (preset.subject !== "Re: Menu" || preset.to.map(x => x.address).join() !== "sales@agency") throw Error(JSON.stringify(preset));
    if (preset.quoted.head !== "On 10:00, Sales wrote:" || preset.thread !== "agency/c1") throw Error("quote");
    let s = Composers.open(Composers.empty(), preset);
    if (s.items[0].kind !== "reply" || s.items[0].subject !== "Re: Menu") throw Error("prefill");
    s = Composers.minimize(s, "c1");
    s = Composers.open(s, Composers.replying(thread, "m2", false, when));
    if (ids(s) !== "c1" || s.items[0].mode !== "open") throw Error("the same reply is shown again, not doubled");
    s = Composers.open(s, Composers.replying(thread, "m1", false, when));
    if (ids(s) !== "c1,c2") throw Error("another message, another composer");
    const draft = {id: "d1", agent: "sales", project: "agency", subject: "S", body: "B"};
    s = Composers.open(s, {draft});
    s = Composers.open(s, {draft});
    if (ids(s) !== "c1,c2,c3" || s.items[2].to[0].address !== "sales@agency" || s.items[2].draft !== "d1") throw Error("a draft opens once");
    """)
  end

  test "closing asks only when something is written" do
    run!("""
    const fresh = Composers.open(Composers.empty(), {}).items[0];
    if (Composers.written(fresh, {subject: " ", body: "\\n", files: 0})) throw Error("blank");
    if (!Composers.written(fresh, {subject: "Hi", body: "", files: 0})) throw Error("a subject counts");
    if (!Composers.written(fresh, {subject: "", body: "x", files: 0})) throw Error("a body counts");
    if (!Composers.written(fresh, {subject: "", body: "", files: 1})) throw Error("a file counts");
    const reply = Composers.open(Composers.empty(), Composers.replying(thread, "", false, when)).items[0];
    if (Composers.written(reply, {subject: "Re: Menu", body: "", files: 0})) throw Error("the prefilled subject is not words");
    const fwd = Composers.open(Composers.empty(), {kind: "forward", subject: "Fwd: Menu", body: "\\n\\n-- Forwarded"}).items[0];
    if (Composers.written(fwd, {subject: "Fwd: Menu", body: "\\n\\n-- Forwarded", files: 0})) throw Error("an untouched forward is not words");
    if (!Composers.written(fwd, {subject: "Fwd: Menu", body: "See\\n\\n-- Forwarded", files: 0})) throw Error("an added line is");
    if (Composers.title("") !== "New message" || Composers.title(" Hi ") !== "Hi") throw Error("title");
    """)
  end

  test "a phone shows the active composer and the strip of all" do
    run!("""
    let s = several();
    let p = Composers.phone(s);
    if (p.tabs.join() !== "c1,c2,c3,c4" || p.active !== "c4") throw Error(JSON.stringify(p));
    s = Composers.minimize(s, "c4");
    p = Composers.phone(s);
    if (p.active !== "" || p.tabs.length !== 4) throw Error("minimized: the mailbox with the strip");
    s = Composers.activate(s, "c2");
    if (Composers.phone(s).active !== "c2") throw Error("a tab opens full screen");
    s = Composers.close(s, "c2");
    if (Composers.phone(s).active !== "" || Composers.phone(s).tabs.length !== 3) throw Error("closed");
    """)
  end
end
