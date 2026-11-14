import { getSiteSettings, resolveExternalApp, setSiteSetting, type AutofillPrompt as ChromeAutofillPrompt, type AutofillPromptAnswer, type PasswordPrompt as ChromePasswordPrompt, type PasswordPromptAnswer } from "@solara/solaracore";
import { useState } from "react";
import { webviews } from "../../lib/webviews";
import { useBrowser } from "../../store/browser";
import { engineProfile } from "../../store/model";
import { patchPage, pageOf, setPopover, usePage } from "../layout/pageState";
import { answerPermission, describePermission } from "./permissions";
import { NativePromptBody, PromptPopover } from "./NativePromptBody";
import { usePromptInputGuard } from "./promptGuard";

const hostOf = (origin: string) => {
  try {
    return new URL(origin).hostname.replace(/^www\./, "") || origin;
  } catch {
    return origin;
  }
};

export function PermissionPrompt({ tabId, left, top }: { tabId: string; left: number; top: number }) {
  const request = usePage(tabId, (p) => p.permission);
  const guard = usePromptInputGuard(request?.id);
  if (!request) return null;
  const { icons, question } = describePermission(request);
  return (
    <PromptPopover key={request.id} width={300} top={top} left={left} modal={false}>
      <NativePromptBody
        spec={{ inputProtectionKey: request.id, icons, title: question, message: "Click the lock to change this any time", buttons: [{ id: "deny", title: "Don't Allow" }, { id: "accept", title: "Allow", primary: true }] }}
        onButton={guard((id: string) => answerPermission(tabId, request.id, id as "deny" | "accept"))}
        onClose={guard(() => answerPermission(tabId, request.id, "dismiss"))}
      />
    </PromptPopover>
  );
}

export const BLOCKED_POPUPS_WIDTH = 360;

export type BlockedPopupsAnswer = "deny" | "once" | "allow" | "dismiss";

export function answerBlockedPopups(tabId: string, answer: BlockedPopupsAnswer) {
  const popups = pageOf(tabId).popups;
  if (answer !== "dismiss" && popups.length) {
    if (answer === "deny") void setSiteSetting(engineProfile(useBrowser.getState().tabs[tabId]?.profileId ?? ""), popups[0]!.origin, "popups", "block");
    else for (const p of popups) void webviews.get(tabId)?.openBlockedPopup(p.id, answer === "allow");
    patchPage(tabId, { popups: [] });
  }
  setPopover(tabId, null);
}

export function openOneBlockedPopup(tabId: string, id: string) {
  void webviews.get(tabId)?.openBlockedPopup(id, false);
  const rest = pageOf(tabId).popups.filter((x) => x.id !== id);
  patchPage(tabId, { popups: rest });
  if (!rest.length) setPopover(tabId, null);
}

export function BlockedPopupsPrompt({ tabId, right, left, top }: { tabId: string; right?: number; left?: number; top: number }) {
  const popups = usePage(tabId, (p) => p.popups);
  if (!popups.length) return null;
  const origin = popups[0]!.origin;
  const site = hostOf(origin);
  const close = () => answerBlockedPopups(tabId, "dismiss");
  const answer = (id: string) => answerBlockedPopups(tabId, id as BlockedPopupsAnswer);
  const openOne = (id: string) => openOneBlockedPopup(tabId, id);
  return (
    <PromptPopover width={BLOCKED_POPUPS_WIDTH} top={top} right={right} left={left} onDismiss={close}>
      <NativePromptBody
        spec={{
          icons: ["macwindow.badge.plus"],
          title: `Always allow pop-ups from ${site}?`,
          message: `Allow ${site} to always open pop-up windows, choose every time, or always deny pop-ups.`,
          buttons: [{ id: "deny", title: "Always Deny" }, { id: "once", title: "Only Once" }, { id: "allow", title: "Always Allow", primary: true }],
          close: false,
          rows: popups.slice(-5).map((p) => ({ id: p.id, icon: "arrow.up.forward.app", title: p.url.replace(/^https?:\/\//, "") || "about:blank" })),
          rowsMore: popups.length > 5 ? `and ${popups.length - 5} more` : null,
        }}
        onButton={answer}
        onRow={openOne}
      />
    </PromptPopover>
  );
}

export async function shouldPromptForPopups(profile: string, origin: string): Promise<boolean> {
  try {
    const settings = await getSiteSettings(profile, origin);
    return settings.popups.isDefault;
  } catch {
    return true;
  }
}

export function showPasswordPrompt(tabId: string, prompt: ChromePasswordPrompt) {
  patchPage(tabId, { passwordPrompt: prompt.state === "saved" ? null : prompt });
}

export function PasswordPrompt({ tabId, right, top }: { tabId: string; right: number; top: number }) {
  const prompt = usePage(tabId, (p) => p.passwordPrompt);
  const [chosen, setChosen] = useState<string | null>(null);
  const guard = usePromptInputGuard(prompt ? `${prompt.origin}|${prompt.username}|${prompt.state}` : null);
  if (!prompt) return null;
  const site = hostOf(prompt.origin);
  const update = prompt.state === "update";
  const username = chosen ?? prompt.username;
  const answer = guard((action: PasswordPromptAnswer) => {
    void webviews.get(tabId)?.resolvePasswordPrompt(action, action === "save" || action === "update" ? { username } : undefined);
    setChosen(null);
    patchPage(tabId, { passwordPrompt: null });
  });
  const choices = update && prompt.usernames.length > 1 ? prompt.usernames : [];
  return (
    <PromptPopover key={`${prompt.origin}|${prompt.username}|${prompt.state}`} width={update ? 310 : 350} top={top} right={right} modal={false}>
      <NativePromptBody
        spec={{
          icons: ["key.fill"],
          title: update ? "Update saved password?" : `Save password for ${site}?`,
          message: update ? `It will be auto-filled on ${site}` : "That way, it'll be auto-filled next time",
          details: [
            choices.length
              ? { kind: "choices", choices: choices.map((name) => ({ id: name, title: name, selected: name === username })) }
              : {
                  kind: "well",
                  sections: [
                    {
                      lines: [
                        { text: username || (prompt.federation ? `Signed in with ${hostOf(prompt.federation)}` : "No username"), strong: true, maxLines: 1 },
                        ...(prompt.passwordLength > 0 ? [{ text: "•".repeat(Math.min(prompt.passwordLength, 16)), tone: "secondary" as const, kern: 1, maxLines: 1 }] : []),
                      ],
                    },
                  ],
                },
          ],
          buttons: [
            ...(!update ? [{ id: "never", title: "Never on This Site" }] : []),
            { id: update ? "nope" : "dismiss", title: "Not Now" },
            { id: update ? "update" : "save", title: update ? "Update" : "Save", primary: true },
          ],
        }}
        onButton={(id) => answer(id as PasswordPromptAnswer)}
        onChoice={setChosen}
        onClose={() => answer("dismiss")}
      />
    </PromptPopover>
  );
}

export function showAutofillPrompt(tabId: string, prompt: ChromeAutofillPrompt | null, id: number) {
  if (prompt) patchPage(tabId, { autofillPrompt: prompt });
  else if (pageOf(tabId).autofillPrompt?.id === id) patchPage(tabId, { autofillPrompt: null });
}

export function AutofillPrompt({ tabId, right, top }: { tabId: string; right: number; top: number }) {
  const prompt = usePage(tabId, (p) => p.autofillPrompt);
  const guard = usePromptInputGuard(prompt?.id);
  if (!prompt) return null;
  const answer = guard((action: AutofillPromptAnswer) => {
    void webviews.get(tabId)?.resolveAutofillPrompt(prompt.id, action);
    patchPage(tabId, { autofillPrompt: null });
  });
  const changes = prompt.changes ?? [];
  const values = (key: "to" | "from") => changes.filter((c) => c[key]).map((c) => c[key]);
  return (
    <PromptPopover key={prompt.id} width={350} top={top} right={right} modal={false}>
      <NativePromptBody
        spec={{
          icons: [prompt.kind === "saveCard" ? "creditcard.fill" : "mappin.and.ellipse"],
          title: prompt.title,
          message: prompt.message || null,
          details: [
            {
              kind: "well",
              sections:
                prompt.kind !== "updateAddress"
                  ? [{ lines: prompt.lines.map((text, i) => ({ text, strong: i === 0, tone: i === 0 ? ("primary" as const) : ("secondary" as const), maxLines: 2 })) }]
                  : prompt.newLabel
                    ? [
                        { label: prompt.newLabel, lines: values("to").map((text) => ({ text: String(text), maxLines: 2 })) },
                        { label: prompt.oldLabel, lines: values("from").map((text) => ({ text: String(text), maxLines: 2 })) },
                      ]
                    : [{ lines: values("to").map((text, i) => ({ text: String(text), strong: i === 0, tone: i === 0 ? ("primary" as const) : ("secondary" as const), maxLines: 2 })) }],
            },
            ...(prompt.footer ? [{ kind: "note" as const, text: prompt.footer }] : []),
          ],
          buttons: [{ id: "decline", title: prompt.decline }, { id: "accept", title: prompt.accept, primary: true }],
        }}
        onButton={(id) => answer(id as AutofillPromptAnswer)}
        onClose={() => answer("dismiss")}
      />
    </PromptPopover>
  );
}

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
