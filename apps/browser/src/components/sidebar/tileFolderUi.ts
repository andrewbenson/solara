import { requireOptionalNativeModule } from "expo-modules-core";
import { create } from "zustand";
import { nativeOwnsWorkspace } from "../../store/nativeStore";

type Open = { windowId: string; folderId: string; native?: boolean; anchor?: { x: number; y: number; width: number; height: number } };

type NativeTileFolders = {
  toggle(windowId: string, folderId: string): Promise<boolean>;
  closeInWindow(windowId: string): boolean;
  folderMenu(windowId: string, folderId: string): Promise<boolean>;
  rename(windowId: string, folderId: string, title: string | null): Promise<boolean>;
  newFolderWithTab(windowId: string, tabId: string): Promise<boolean>;
  leaveFolder(tabId: string): Promise<boolean>;
  stripGroupMenu(windowId: string, groupId: string): Promise<boolean>;
  stripTileMenu(windowId: string, folderId: string): Promise<boolean>;
};

const nativeFolders = requireOptionalNativeModule<NativeTileFolders>("SolaraFolderPanel");

export const nativeTileFolders = () => (nativeOwnsWorkspace() && nativeFolders?.toggle ? nativeFolders : null);

export const useFolderPanel = create<{ open: Open | null }>()(() => ({ open: null }));

let mirroredSeq = 0;

export function mirrorFolderPanel(windowId: string, folderId: string, seq: number) {
  if (seq <= mirroredSeq) return;
  mirroredSeq = seq;
  useFolderPanel.setState({ open: windowId && folderId ? { windowId, folderId, native: true } : null });
}

export function closeFolderPanelIn(windowId: string | undefined): boolean {
  return !!windowId && nativeFolders?.closeInWindow?.(windowId) === true;
}
