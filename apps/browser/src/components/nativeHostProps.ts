export type LiveChromeLists = { loading: string[]; playing: string[]; sleeping: string[] };

type Glow = { color: string; opacity: number; radius: number };

export type StripHostProps = {
  profileId: string;
  dark: boolean;
  theme: Record<string, string>;
  border: string[];
  glow: Glow;
  floating: boolean;
  pageWidth: number;
  playing: string[];
  sleeping: string[];
  engines: Record<string, string>;
  capture: Record<string, string>;
  bands: Record<string, string>;
  closeHint: string | null;
  newTabMark: string | null;
  pages: unknown;
  selection: readonly string[];
  iconRing?: boolean;
};

export type SidebarHostProps = {
  profileId: string;
  dark: boolean;
  theme: Record<string, string>;
  border: string[];
  glow: Glow;
  selection: readonly string[];
  loading: string[];
  playing: string[];
  sleeping: string[];
  closeHint: string | null;
  backHint: string | null;
  renaming: string | null;
  addressBar: boolean;
  tidy: boolean;
  clear: boolean;
  iconRing: boolean;
  newTabAtTop: boolean;
  incognito: boolean;
  cleaned: number;
  upsell: number | null;
  product: string;
  engines: Record<string, string>;
  developer: string[];
  newTabMark: string | null;
  pages: unknown;
  player: unknown;
  pip: string[];
  capture: Record<string, string>;
  badge: string[];
};

const OWNED: LiveChromeLists = { loading: [], playing: [], sleeping: [] };

type HostInput<Props> = Omit<Props, keyof LiveChromeLists> & { ownsLive: boolean; live: Pick<LiveChromeLists, Extract<keyof Props, keyof LiveChromeLists>> };

export function stripHostProps({ ownsLive, live, ...rest }: HostInput<StripHostProps>): StripHostProps {
  const lists = ownsLive ? OWNED : live;
  return { ...rest, playing: lists.playing, sleeping: lists.sleeping };
}

export function sidebarHostProps({ ownsLive, live, ...rest }: HostInput<SidebarHostProps>): SidebarHostProps {
  const lists = ownsLive ? OWNED : live;
  return { ...rest, loading: lists.loading, playing: lists.playing, sleeping: lists.sleeping };
}

type ChromeLiveState = {
  windows: Record<string, { tabIds: readonly string[] } | undefined>;
  live: Record<string, { isLoading?: boolean; playingAudio?: boolean } | undefined>;
};

export function chromeLiveIds(state: ChromeLiveState, windowId: string, key: "isLoading" | "playingAudio", ownsLive: boolean): string {
  if (ownsLive) return "";
  let out = "";
  for (const id of state.windows[windowId]?.tabIds ?? []) if (state.live[id]?.[key]) out += (out ? "," : "") + id;
  return out;
}

export function chromeSleeping(discarded: Record<string, boolean | undefined>, ownsLive: boolean): string[] {
  return ownsLive ? OWNED.sleeping : Object.keys(discarded).filter((id) => discarded[id]);
}
