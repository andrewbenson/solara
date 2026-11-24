import { nativeTileFolders } from "../sidebar/tileFolderUi";

export async function openFolderMenu(windowId: string, groupId: string) {
  await nativeTileFolders()?.stripGroupMenu(windowId, groupId);
}

export async function openTileFolderStripMenu(windowId: string, folderId: string) {
  await nativeTileFolders()?.stripTileMenu(windowId, folderId);
}
