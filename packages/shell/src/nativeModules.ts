import { requireNativeModule, requireOptionalNativeModule } from "expo-modules-core";
import type { AppModule } from "./app";
import type { CliNative } from "./cli";
import type { DockSelectionNative, GlassEffectNative, HairlineNative, InlineCompletionNative, PopoverBubbleNative, ShellNative } from "./index";
import type { CalendarNative, KeychainNative } from "./live";
import type { FileDropNative, MagnifyAreaNative, SystemNative } from "./system";

export type ShellNativeModules = {
  SolaraShell: ShellNative;
  SolaraApp: AppModule;
  SolaraSystem: SystemNative;
  SolaraCalendar: CalendarNative;
  SolaraKeychain: KeychainNative;
  SolaraGlassEffect: GlassEffectNative;
  SolaraDockSelection: DockSelectionNative;
  SolaraInlineCompletion: InlineCompletionNative;
};

export type ShellOptionalNativeModules = {
  SolaraPopoverBubble: PopoverBubbleNative;
  SolaraHairline: HairlineNative;
  SolaraMagnifyArea: MagnifyAreaNative;
  SolaraFileDrop: FileDropNative;
  SolaraCli: CliNative;
};

export const nativeModule = <Name extends keyof ShellNativeModules>(name: Name) => requireNativeModule<ShellNativeModules[Name]>(name);

export const optionalNativeModule = <Name extends keyof ShellOptionalNativeModules>(name: Name) =>
  requireOptionalNativeModule<ShellOptionalNativeModules[Name]>(name);
