.pragma library

// Colours as "#rrggbb" strings; channels as 0 to 1.
function rgb(value) {
  const match = String(value).match(/^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/);
  return match ? [1, 2, 3].map(i => parseInt(match[i], 16) / 255) : null;
}

function luminance(color) {
  const channel = value => value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
  return 0.2126 * channel(color[0]) + 0.7152 * channel(color[1]) + 0.0722 * channel(color[2]);
}

function contrast(a, b) {
  const first = luminance(a);
  const second = luminance(b);
  return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05);
}

function hex(color) {
  return "#" + color.map(channel => Math.round(channel * 255).toString(16).padStart(2, "0")).join("");
}

// `wanted` moved toward `ink` until it reads at least `ratio` (4.5:1 when
// not given) on `base`; `ink` itself when the colours are not hex or none of
// the steps does.
function readable(wanted, base, ink, ratio) {
  const least = ratio || 4.5;
  const color = rgb(wanted);
  const backgroundColor = rgb(base);
  const foregroundColor = rgb(ink);
  if (!color || !backgroundColor || !foregroundColor) return ink;
  for (let step = 0; step <= 20; step++) {
    const mixed = hex(color.map((channel, index) => channel + (foregroundColor[index] - channel) * step / 20));
    if (contrast(rgb(mixed), backgroundColor) >= least) return mixed;
  }
  return ink;
}
