import { nativeSettingsAvailable, publishSettingsTopic, serveNativeSettings, type SettingsHandler } from "@solara/settings";
import { useCli } from "../../lib/cliControl";
import { compactMemory } from "../../lib/memoryTrim";
import { useBrowser } from "../../store/browser";
import { extensionsProfileId } from "../extensions/store";
import { autofillHandlers } from "./native/autofill";
import { extensionsHandlers } from "./native/extensions";
import { replicaHandlers } from "./native/replica";
import { bookmarkRestorationHandlers } from "./native/bookmarks";
import { liveHandlers } from "./native/live";
import { onboardingHandlers, publishOnboarding } from "./native/onboarding";
import { passwordsHandlers, publishPasswords } from "./native/passwords";
import { privacyHandlers, publishPrivacy } from "./native/privacy";
import { profilesHandlers, publishProfiles } from "./native/profiles";
import { shortcutsHandlers } from "./native/shortcuts";
import { publishSync, syncHandlers } from "./native/sync";

const handlers: Record<string, SettingsHandler> = {};
const publishers: (() => void)[] = [];
let started = false;
let bridgeStarted = false;

export function addNativeSettingsHandlers(added: Record<string, SettingsHandler>, publish?: () => void) {
  Object.assign(handlers, added);
  if (!publish) return;
  publishers.push(publish);
  if (started) publish();
}

function chooseTabLayout(layout: "sidebar" | "top") {
  const s = useBrowser.getState();
  s.updateSettings({ tabLayout: layout });
  for (const w of Object.values(s.windows)) {
    if ((w.tabLayout ?? s.settings.tabLayout) !== layout) useBrowser.getState().toggleTabLayout(w.id);
  }
  useBrowser.getState().updateSettings({ tabLayout: layout });
}

const coreHandlers: Record<string, SettingsHandler> = {
  "tabs.chooseLayout": (layout: "sidebar" | "top") => chooseTabLayout(layout),

  "memory.compact": () => compactMemory(),
};

function cliTopic() {
  const cli = useCli.getState();
  return {
    server: cli.server ? { state: cli.server.state, reason: cli.server.reason ?? null, connections: cli.server.connections ?? null } : null,
    installing: !!cli.installing,
    step: cli.step ?? null,
    installedVersion: cli.installedVersion ?? null,
    binPath: cli.binPath ?? null,
    error: cli.error ?? null,
  };
}

function updateChecksNote() {
  return null;
}

export function startNativeSettings(): boolean {
  if (!bridgeStarted) {
    bridgeStarted = true;
    Object.assign(
      handlers,
      coreHandlers,
      privacyHandlers,
      passwordsHandlers,
      autofillHandlers,
      extensionsHandlers,
      shortcutsHandlers,
      profilesHandlers,
      syncHandlers,
      liveHandlers,
      bookmarkRestorationHandlers,
      replicaHandlers,
      onboardingHandlers,
    );
    serveNativeSettings(handlers);
  }
  if (started) return true;
  if (!nativeSettingsAvailable()) return false;
  started = true;
  publishSettingsTopic("advanced.cli", cliTopic());
  publishSettingsTopic("about.updateChecksNote", updateChecksNote());
  useCli.subscribe(() => publishSettingsTopic("advanced.cli", cliTopic()));
  for (const publish of [publishPrivacy, publishPasswords, publishProfiles, publishSync, publishOnboarding, ...publishers]) publish();
  return true;
}
