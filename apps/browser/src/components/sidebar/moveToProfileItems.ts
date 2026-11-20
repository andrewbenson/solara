import type { MenuItem } from "@solara/shell";
import type { Profile, Tab } from "../../store/types";

type ProfileSource = { profileOrder: string[]; profiles: Record<string, Profile | undefined> };

export function moveToProfileItems(s: ProfileSource, tab: Pick<Tab, "profileId">, incognito: boolean): MenuItem[] {
  if (incognito) return [];
  return [
    ...s.profileOrder.map((id) => ({ id: `profile:${id}`, title: s.profiles[id]?.name ?? "", checked: id === tab.profileId, enabled: id !== tab.profileId })),
    { id: "profile:new", title: "New Profile…" },
    { separator: true },
  ];
}
