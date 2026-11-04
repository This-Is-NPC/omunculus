defmodule Omunculus.GuiColourTest do
  use ExUnit.Case, async: true

  @theme Path.expand("../../apps/kit/ui/Theme.qml", __DIR__)

  defp fallback do
    source = File.read!(@theme)

    for key <- ~w(background foreground accent muted green yellow red), into: %{} do
      [_, hex] = Regex.run(~r/\b#{key}: "(#[0-9a-f]{6})"/, source)
      {key, hex}
    end
  end

  test "luminance, contrast and readable keep the theme's arithmetic" do
    script = """
    const near = (a, b) => Math.abs(a - b) < 0.05;
    if (!near(Colour.contrast(Colour.rgb("#000000"), Colour.rgb("#ffffff")), 21)) throw Error("black on white");
    if (!near(Colour.contrast(Colour.rgb("#dccbb2"), Colour.rgb("#140c09")), 12.2)) throw Error("foreground");
    if (!near(Colour.contrast(Colour.rgb("#8a7868"), Colour.rgb("#140c09")), 4.57)) throw Error("dim");
    if (Colour.rgb("nope") !== null) throw Error("not hex");
    if (Colour.readable("nope", "#000000", "#ffffff") !== "#ffffff") throw Error("ink");
    const lifted = Colour.readable("#333333", "#000000", "#ffffff");
    if (Colour.contrast(Colour.rgb(lifted), Colour.rgb("#000000")) < 4.5) throw Error("lifted");
    if (Colour.readable("#ffffff", "#000000", "#ffffff") !== "#ffffff") throw Error("already readable");
    const faint = Colour.readable("#333333", "#000000", "#ffffff", 3);
    const ratio = Colour.contrast(Colour.rgb(faint), Colour.rgb("#000000"));
    if (ratio < 3 || ratio >= Colour.contrast(Colour.rgb(lifted), Colour.rgb("#000000"))) throw Error("faint");
    """

    assert {"", 0} = Omunculus.GuiModules.run(["Colour"], script)
  end

  test "hue, hueApart and spread order colours by how different their hues are" do
    script = """
    const near = (a, b) => Math.abs(a - b) < 0.01;
    if (!near(Colour.hue("#ff0000"), 0) || !near(Colour.hue("#00ff00"), 1 / 3) || !near(Colour.hue("#0000ff"), 2 / 3)) throw Error("primaries");
    if (Colour.hue("#808080") !== -1) throw Error("grey has no hue");
    if (!near(Colour.hueApart(0.95, 0.05), 0.1)) throw Error("wraps around");
    if (Colour.hueApart(-1, 0.5) !== 0) throw Error("grey is no apart");
    // red, a near red, green, blue: the near red comes last.
    const order = Colour.spread(["#ff0000", "#ff2a00", "#00ff00", "#0000ff"]);
    if (order[0] !== "#ff0000" || order[3] !== "#ff2a00" || order.length !== 4) throw Error("spread " + order);
    """

    assert {"", 0} = Omunculus.GuiModules.run(["Colour"], script)
  end

  test "dim and foreground reach 4.5:1 on every surface the thread uses" do
    themes = [
      fallback(),
      %{
        "background" => "#140c09",
        "foreground" => "#dccbb2",
        "accent" => "#c79a42",
        "muted" => "#8a7868",
        "green" => "#7fae6b",
        "yellow" => "#c79a42",
        "red" => "#c4604f"
      }
    ]

    script = """
    const themes = #{Jason.encode!(themes)};
    const over = (top, alpha, base) => top.map((c, i) => c * alpha + base[i] * (1 - alpha));
    for (const t of themes) {
      const bg = Colour.rgb(t.background);
      const fg = Colour.rgb(t.foreground);
      const tones = [t.accent, t.green, t.yellow, t.red].map(Colour.rgb);
      const surfaces = [bg, over(fg, 0.05, bg), over(fg, 0.07, bg)]
        .concat(tones.flatMap(tone => [0.07, 0.12].map(alpha => over(tone, alpha, bg))));
      const hexOf = rgb => "#" + rgb.map(c => Math.round(c * 255).toString(16).padStart(2, "0")).join("");
      for (const exact of surfaces) {
        const base = hexOf(exact);
        const surface = Colour.rgb(base);
        const dim = Colour.readable(t.muted, base, t.foreground);
        if (Colour.contrast(Colour.rgb(dim), surface) < 4.5) throw Error("dim on " + base + " " + JSON.stringify(t));
        if (Colour.contrast(fg, surface) < 4.5) throw Error("foreground on " + base + " " + JSON.stringify(t));
      }
    }
    """

    assert {"", 0} = Omunculus.GuiModules.run(["Colour"], script)
  end
end
