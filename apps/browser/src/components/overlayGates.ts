export function pillPresence(mounted: boolean, revealed: boolean, shown: boolean) {
  return { mounted: mounted || shown, shown: shown && revealed };
}

export function siteControlsMounted(open: boolean, latched: boolean) {
  return open || latched;
}

export function engineOfferMounted(offer: unknown, newTabShown: boolean, nativePrompts: boolean) {
  return !!offer && !newTabShown && !nativePrompts;
}
