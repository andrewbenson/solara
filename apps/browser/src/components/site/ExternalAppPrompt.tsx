import { resolveExternalApp } from "@solara/solaracore";
import { useState } from "react";
import { pageOf, patchPage, usePage } from "../layout/pageState";
import { NativePromptBody, PromptPopover } from "./NativePromptBody";
import { usePromptInputGuard } from "./promptGuard";

export function ExternalAppPrompt({ tabId, left, top }: { tabId: string; left: number; top: number }) {
  const request = usePage(tabId, (p) => p.externalApp);
  const [always, setAlways] = useState(false);
  const guard = usePromptInputGuard(request?.id);
  if (!request) return null;
  const answer = guard((open: boolean) => {
    answerExternalApp(tabId, open, open && always);
    setAlways(false);
  });
  const setAlwaysGuarded = guard(setAlways);
  return (
    <PromptPopover key={request.id} width={340} top={top} left={left} modal={false}>
      <NativePromptBody
        spec={{
          icons: request.icon ? [] : [request.app ? "app" : "questionmark.app.dashed"],
          image: request.icon,
          title: request.title,
          message: request.message,
          details: request.remember ? [{ kind: "checkbox", label: request.remember, value: always }] : [],
          buttons: request.app ? [{ id: "cancel", title: "Cancel" }, { id: "open", title: "Open", primary: true }] : [{ id: "ok", title: "OK", primary: true }],
        }}
        onButton={(id) => answer(id === "open")}
        onToggle={setAlwaysGuarded}
        onClose={() => answer(false)}
      />
    </PromptPopover>
  );
}

export function answerExternalApp(tabId: string, open: boolean, remember = false) {
  const request = pageOf(tabId).externalApp;
  if (!request) return;
  patchPage(tabId, { externalApp: null });
  void resolveExternalApp(request.id, open, remember);
}
