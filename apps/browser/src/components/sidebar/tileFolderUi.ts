import { requireOptionalNativeModule } from "expo-modules-core";
import { create } from "zustand";
import { nativeOwnsWorkspace } from "../../store/nativeStore";

type Open = { windowId: string; folderId: string; native?: boolean; anchor?: { x: number; y: number; width: number; height: number } };

type NativeTileFolders = {
  toggle(windowId: string, folderId: string): Promise<boolean>;
  close(windowId: string | null): Promise<boolean>;
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

export const folderPanel = () => useFolderPanel.getState().open;

function closeOpen(open: Open, windowId: string | null) {
  if (open.native && nativeFolders?.close) {
    void nativeFolders.close(windowId).then((closed) => {
      if (!closed && useFolderPanel.getState().open === open) useFolderPanel.setState({ open: null });
    });
    return;
  }
  if (useFolderPanel.getState().open === open) useFolderPanel.setState({ open: null });
}

export function closeFolderPanel() {
  const open = folderPanel();
  if (open) closeOpen(open, null);
}

export function closeFolderPanelIn(windowId: string | undefined): boolean {
  const open = folderPanel();
  if (!windowId || !open || open.windowId !== windowId) return false;
  closeOpen(open, windowId);
  return true;
}

export async function toggleFolderPanel(windowId: string, folderId: string) {
  await nativeTileFolders()?.toggle(windowId, folderId);
}

export async function renameFolder(windowId: string, folderId: string, title = "Rename Folder") {
  await nativeTileFolders()?.rename(windowId, folderId, title);
}

export async function newFolderWithTab(windowId: string, tabId: string) {
  await nativeTileFolders()?.newFolderWithTab(windowId, tabId);
}

export async function removeFromFolder(tabId: string) {
  await nativeTileFolders()?.leaveFolder(tabId);
}

export async function openTileFolderMenu(windowId: string, folderId: string) {
  await nativeTileFolders()?.folderMenu(windowId, folderId);
}
