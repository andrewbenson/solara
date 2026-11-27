import { type AutofillPrompt as ChromeAutofillPrompt, type AutofillPromptAnswer, type PasswordPrompt as ChromePasswordPrompt, type PasswordPromptAnswer } from "@solara/solaracore";
import { useState } from "react";
import { webviews } from "../../lib/webviews";
import { patchPage, pageOf, usePage } from "../layout/pageState";
import { NativePromptBody, PromptPopover } from "./NativePromptBody";
import { usePromptInputGuard } from "./promptGuard";

const hostOf = (origin: string) => {
  try {
    return new URL(origin).hostname.replace(/^www\./, "") || origin;
  } catch {
    return origin;
  }
};

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
