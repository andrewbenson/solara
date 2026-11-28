import type { CliControlStatus } from "@solara/solaracore";
import { nativeInstallCli } from "@solara/settings";
import { installedCliVersion, readDocument, systemInfo, type CliInstallResult } from "@solara/shell";
import { create } from "zustand";
import { nativeSafeMode } from "../store/nativeStore";

type Saved = { binPath?: string | null; error?: string | null };

export type CliInstallReason = "onboarding" | "settings" | "upgrade";

export const cliProduct = (): string => systemInfo().appName?.trim() || "Solara";

export const cliCommand = (): string => cliProduct().toLowerCase();

type CliState = {
  server: CliControlStatus | null;
  installing: CliInstallReason | null;
  step: string | null;
  installedVersion: string | null;
  binPath: string | null;
  error: string | null;
};

function readSaved(): Saved {
  try {
    const json = readDocument("solara-cli.json");
    return json ? (JSON.parse(json) as Saved) : {};
  } catch {
    return {};
  }
}

const saved = readSaved();

export const useCli = create<CliState>(() => ({
  server: null,
  installing: null,
  step: null,
  installedVersion: installedCliVersion(),
  binPath: saved.binPath ?? null,
  error: saved.error ?? null,
}));

export const useCliIndicator = create<{ shown: boolean }>(() => ({ shown: false }));

let running: Promise<CliInstallResult> | null = null;

export function installCliInBackground(reason: CliInstallReason): Promise<CliInstallResult> {
  if (reason === "upgrade" && nativeSafeMode()) return Promise.resolve({ ok: false, appVersion: "", error: "Automatic CLI upgrades are paused in safe mode.", lines: [] });
  if (running) return running;
  useCli.setState({ installing: reason, step: null });
  running = (nativeInstallCli(reason) as Promise<CliInstallResult>)
    .catch((e: unknown): CliInstallResult => ({ ok: false, appVersion: "", error: e instanceof Error ? e.message : String(e), lines: [] }))
    .then((result) => {
      running = null;
      const installedVersion = installedCliVersion();
      if (result.ok) {
        useCli.setState({ installing: null, step: null, installedVersion, binPath: result.binPath ?? null, error: null });
      } else {
        const error = result.error ?? "The installer stopped.";
        useCli.setState({ installing: null, step: null, installedVersion, error });
      }
      return result;
    });
  return running;
}

if (__DEV__) (globalThis as { acCli?: unknown }).acCli = { store: useCli, indicator: useCliIndicator, install: installCliInBackground };
