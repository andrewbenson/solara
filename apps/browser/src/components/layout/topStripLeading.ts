export function topStripLeading(width: number, profileWidth: number, windowFullscreen: boolean) {
  const profileLeft = windowFullscreen ? 8 : 86;
  const profileSlot = profileWidth > 0 ? Math.max(windowFullscreen ? 84 : 0, profileWidth + 8) : 0;
  const leading = profileLeft + profileSlot;
  const right = 84;
  return { profileLeft, profileSlot, leading, right, pageWidth: Math.max(0, width - leading - right) };
}
