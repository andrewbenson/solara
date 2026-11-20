import { prompt, showMenu } from "@solara/shell";
import { requireOptionalNativeModule } from "expo-modules-core";
import { create } from "zustand";
import { useBrowser } from "../../store/browser";
import { plural } from "../../store/model";
import { dissolveTileFolder, folderIn, folderMembers, leaveTileFolder, newTileFolder, renameTileFolder } from "../../store/tileFolders";
import { dismissHover } from "./hover";
import { measureRow } from "./state";
import { encodeCommand } from "@solara/store";
import { nativeOwnsWorkspace, nativeWrite } from "../../store/nativeStore";

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
  if (await nativeTileFolders()?.toggle(windowId, folderId)) return;
  const open = folderPanel();
  if (open?.windowId === windowId && open.folderId === folderId) return closeFolderPanel();
  dismissHover();
  const anchor = await measureRow(windowId, folderId);
  if (anchor) useFolderPanel.setState({ open: { windowId, folderId, anchor } });
}

const store = () => useBrowser.getState();

export async function renameFolder(windowId: string, folderId: string, title = "Rename Folder") {
  if (await nativeTileFolders()?.rename(windowId, folderId, title)) return;
  const folder = folderIn(store(), windowId, folderId);
  if (!folder) return;
  const name = await prompt({ title, value: folder.name, placeholder: "Folder", confirmTitle: "Update", windowId });
  if (name === null) return;
  if (nativeOwnsWorkspace()) nativeWrite(encodeCommand("renameTileFolder", [windowId, folderId, name]));
  else useBrowser.setState((s) => renameTileFolder(s, windowId, folderId, name));
}

export async function newFolderWithTab(windowId: string, tabId: string) {
  if (await nativeTileFolders()?.newFolderWithTab(windowId, tabId)) return;
  let folderId: string | null | undefined;
  if (nativeOwnsWorkspace()) folderId = nativeWrite(encodeCommand("newTileFolder", [[tabId]]))?.result as string | undefined;
  else {
    const made = newTileFolder(store(), [tabId]);
    folderId = made.folderId;
    if (folderId) useBrowser.setState(made.state);
  }
  if (!folderId) return;
  void renameFolder(windowId, folderId, "Name Folder");
}

export async function removeFromFolder(tabId: string) {
  if (await nativeTileFolders()?.leaveFolder(tabId)) return;
  if (nativeOwnsWorkspace()) nativeWrite(encodeCommand("leaveTileFolder", [[tabId]]));
  else useBrowser.setState((s) => leaveTileFolder(s, [tabId]));
}

export async function openTileFolderMenu(windowId: string, folderId: string) {
  if (await nativeTileFolders()?.folderMenu(windowId, folderId)) return;
  dismissHover();
  const members = folderMembers(store(), windowId, folderId);
  if (!members.length) return;
  const choice = await showMenu([
    { id: "rename", title: "Rename Folder…", symbol: "character.cursor.ibeam" },
    { id: "remove", title: "Remove Folder", symbol: "folder.badge.minus" },
    { separator: true },
    { id: "unpin", title: `Unpin ${plural(members.length, "Tab")}`, symbol: "pin.slash" },
  ]);
  if (choice === "rename") void renameFolder(windowId, folderId);
  else if (choice === "remove") {
    if (nativeOwnsWorkspace()) nativeWrite(encodeCommand("dissolveTileFolder", [windowId, folderId]));
    else useBrowser.setState((s) => dissolveTileFolder(s, windowId, folderId));
  }
  else if (choice === "unpin") store().pinTabs(folderMembers(store(), windowId, folderId), false);
  if (choice) closeFolderPanel();
}
