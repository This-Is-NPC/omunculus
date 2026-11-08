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

// The hue of "#rrggbb" as a turn (0 to 1), or -1 for a grey, which has none.
function hue(color) {
  const [r, g, b] = rgb(color);
  const top = Math.max(r, g, b);
  const spread = top - Math.min(r, g, b);
  if (spread === 0 || spread / (1 - Math.abs(top + Math.min(r, g, b) - 1)) <= 0.05) return -1;
  const sector = top === r ? ((g - b) / spread + 6) % 6 : top === g ? (b - r) / spread + 2 : (r - g) / spread + 4;
  return sector / 6;
}

// How far apart two hues are, as a turn (0 to 0.5); 0 when either is grey.
function hueApart(a, b) {
  if (a < 0 || b < 0) return 0;
  const gap = Math.abs(a - b);
  return Math.min(gap, 1 - gap);
}

// `colors` reordered so each takes the hue furthest from those before it,
// the first kept: its first few are the most different.
function spread(colors) {
  const chosen = colors.slice(0, 1);
  const rest = colors.slice(1);
  const nearest = color => Math.min.apply(null, chosen.map(other => hueApart(hue(color), hue(other))));
  while (rest.length > 0) {
    const far = rest.reduce((best, color) => nearest(color) > nearest(best) ? color : best);
    chosen.push(far);
    rest.splice(rest.indexOf(far), 1);
  }
  return chosen;
}

// `hex` with its hue turned by `by` of a turn, saturation and lightness kept.
function turn(color, by) {
  const [r, g, b] = rgb(color);
  const top = Math.max(r, g, b);
  const low = Math.min(r, g, b);
  const light = (top + low) / 2;
  const spread = top - low;
  const saturation = spread === 0 ? 0 : spread / (1 - Math.abs(2 * light - 1));
  const at = (((hue(color) + by) % 1) + 1) % 1 * 6;
  const chroma = (1 - Math.abs(2 * light - 1)) * saturation;
  const second = chroma * (1 - Math.abs(at % 2 - 1));
  const parts = [[chroma, second, 0], [second, chroma, 0], [0, chroma, second], [0, second, chroma], [second, 0, chroma], [chroma, 0, second]][Math.floor(at) % 6];
  return hex(parts.map(part => part + light - chroma / 2));
}

// Up to `count` agent colours from `wanted`, each made readable on `base`.
// One is kept only when it is `apart` away in RGB from every colour of
// `states` (accent, success, warning, error) and `ink`, and a `gap` of hue from those of `states`
// and from the ones already kept. Turns of the hues kept fill the rest, then
// the result is ordered by `spread`.
function palette(wanted, count, base, ink, states, apart, gap) {
  const picked = [];
  const avoid = states.concat([ink]).map(rgb);
  const take = color => {
    if (picked.length === count) return;
    const readableColor = readable(color, base, ink);
    const value = rgb(readableColor);
    if (avoid.some(other => Math.hypot(value[0] - other[0], value[1] - other[1], value[2] - other[2]) < apart)) return;
    const near = other => hueApart(hue(readableColor), hue(other)) < gap - 0.001;
    if (states.some(near) || picked.some(near)) return;
    picked.push(readableColor);
  };
  wanted.forEach(take);
  const own = picked.slice();
  for (let step = 1; step < 10; step++)
    for (const color of own)
      if (hue(color) >= 0) take(turn(color, step / 10));
  return spread(picked);
}
