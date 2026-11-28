import { Cef } from "./native";
import { WebKit } from "./webkit";

export type ExternalAppAllowance = { origin: string; scheme: string; app: string | null; icon: string | null };

export const getExternalAppAllowances = async (profile: string): Promise<ExternalAppAllowance[]> => {
  const [chromium, webkit] = await Promise.all([Cef.getExternalAppAllowances(profile), WebKit?.externalAppAllowances(profile).catch(() => []) ?? []]);
  const seen = new Set(chromium.map((a) => `${a.origin}|${a.scheme}`));
  return [...chromium, ...webkit.filter((a) => !seen.has(`${a.origin}|${a.scheme}`))];
};
export const removeExternalAppAllowance = (profile: string, origin: string, scheme: string) =>
  Promise.all([Cef.removeExternalAppAllowance(profile, origin, scheme), WebKit?.removeExternalAppAllowance(profile, origin, scheme)]).then(() => {});
