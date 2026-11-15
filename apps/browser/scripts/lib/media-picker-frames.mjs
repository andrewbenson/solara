export function mediaPickerFrames(contentWidth) {
  const paneLeft = 190;
  const paneWidth = contentWidth - paneLeft - 7;
  const top = 6 + 41 + 8;
  const castWidth = Math.min(340, paneWidth - 24);
  const shareWidth = Math.min(460, paneWidth - 24);
  return {
    cast: [paneLeft + paneWidth - 8 - castWidth, top, castWidth, 185],
    share: [paneLeft + (paneWidth - shareWidth) / 2, top, shareWidth, 423],
  };
}
