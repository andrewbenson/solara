const appWindow = (w, level) => level(w) === 0 && w.w > 400 && w.h > 300;
const inside = (inner, outer) => inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.w <= outer.x + outer.w && inner.y + inner.h <= outer.y + outer.h;

export function dialogOver(before, after, level) {
  const seen = new Set(before.map((w) => w.id));
  for (const dialog of after) {
    if (seen.has(dialog.id) || level(dialog) < 0 || dialog.w < 200 || dialog.h < 150) continue;
    const owner = after.slice(after.indexOf(dialog) + 1)
      .find((w) => appWindow(w, level) && w.w > dialog.w && w.h > dialog.h && inside(dialog, w));
    if (owner) return { dialog, owner };
  }
  return null;
}
