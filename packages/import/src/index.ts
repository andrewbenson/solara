import { requireNativeModule } from "expo-modules-core";

export type ImportKind =
  | "bookmarks"
  | "history"
  | "tabs"
  | "passwords"
  | "cookies"
  | "autofill"
  | "spaces"
  | "pinnedTabs"
  | "favorites";

export type BrowserFamily = "chromium" | "firefox" | "safari" | "arc" | "automation";

export type SpaceSummary = {
  id: string;
  name: string;
  color?: string;
  emoji?: string;
  icon?: string;
  pinnedCount: number;
  tabCount: number;
  theme?: string;
};

export type BrowserProfile = {
  id: string;
  name: string;
  path: string;
  email?: string;
  avatarPath?: string;
  color?: string;
  isDefault: boolean;
  available: ImportKind[];
  spaces?: SpaceSummary[];
  tabsNeedKey?: boolean;
};

export type BrowserSource = {
  id: string;
  name: string;
  family: BrowserFamily;
  appPath?: string;
  iconPath?: string;
  requiresExport: boolean;
  needsKeychain: boolean;
  needsFullDiskAccess?: boolean;
  keychainService?: string;
  profiles: BrowserProfile[];
  sidebar?: "arc" | "zen";
};

export type Credential = {
  url: string;
  username: string;
  password: string;
  realm?: string;
  title?: string;
  note?: string;
  otpAuth?: string;
  created?: number;
  lastUsed?: number;
  timesUsed?: number;
};

export class ImportError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
    this.name = "ImportError";
  }
}

const Native = requireNativeModule<{
  listBrowsers(): Promise<string>;
  importPasswordsCSV(path: string): Promise<string>;
  chooseImportFile(kind: "passwordsCSV"): Promise<string | null>;
}>("SolaraImportAdapter");

async function call<T>(promise: Promise<string | null>): Promise<T> {
  try {
    const json = await promise;
    return (json == null ? undefined : JSON.parse(json)) as T;
  } catch (e) {
    const err = e as { code?: string; message?: string };
    throw new ImportError(err.code ?? "unreadable", err.message ?? String(e));
  }
}

export const listBrowsers = () => call<BrowserSource[]>(Native.listBrowsers());

export const importPasswordsCSV = (path: string) => call<Credential[]>(Native.importPasswordsCSV(path));

export const chooseImportFile = (kind: "passwordsCSV") => Native.chooseImportFile(kind);
