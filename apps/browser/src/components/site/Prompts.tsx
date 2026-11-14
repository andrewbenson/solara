import { getSiteSettings, resolveExternalApp, setSiteSetting, type AutofillPrompt as ChromeAutofillPrompt, type AutofillPromptAnswer, type PasswordPrompt as ChromePasswordPrompt, type PasswordPromptAnswer } from "@solara/solaracore";
import { Symbol } from "@solara/shell";
import { useState } from "react";
import { Image, Pressable, Text, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { webviews } from "../../lib/webviews";
import { useBrowser } from "../../store/browser";
import { engineProfile } from "../../store/model";
import { useHover } from "../primitives";
import { PANEL, PanelCloseButton, Popover, PopoverRow, PopoverSeparator, PromptButton } from "../layout/controls";
import { Checkbox } from "../settings/controls";
import { patchPage, pageOf, setPopover, usePage } from "../layout/pageState";
import { answerPermission, describePermission } from "./permissions";
import { nativeToolbarAvailable } from "@solara/settings";
import { NativePromptBody, nativePromptFrames, PromptPopover } from "./NativePromptBody";
import { usePromptInputGuard } from "./promptGuard";

const hostOf = (origin: string) => {
  try {
    return new URL(origin).hostname.replace(/^www\./, "") || origin;
  } catch {
    return origin;
  }
};

export function PromptBody({
  icons,
  image,
  title,
  message,
  detail,
  children,
}: {
  icons: string[];
  image?: string | null;
  title: string;
  message?: string | null;
  detail?: React.ReactNode;
  children: React.ReactNode;
}) {
  const theme = useTheme();
  return (
    <View style={{ padding: PANEL.inset, gap: 10 }}>
      <View style={{ flexDirection: "row", gap: 6 }}>
        {image ? <Image source={{ uri: image }} style={{ width: 32, height: 32, marginLeft: -1, marginVertical: -1 }} /> : null}
        {icons.map((icon) => (
          <View key={icon} style={{ width: 30, height: 30, borderRadius: 8, alignItems: "center", justifyContent: "center", backgroundColor: theme.dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.06)" }}>
            <Symbol name={icon} size={14} color={theme.icon} style={{ width: 20, height: 20 }} />
          </View>
        ))}
      </View>
      <View style={{ gap: 3 }}>
        <Text style={{ fontSize: 13, fontWeight: "600", color: theme.textPrimary }}>{title}</Text>
        {message ? <Text style={{ fontSize: 12, color: theme.textSecondary }}>{message}</Text> : null}
      </View>
      {detail}
      <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8, justifyContent: "flex-end", marginTop: 2 }}>{children}</View>
    </View>
  );
}

export function PermissionPrompt({ tabId, left, top }: { tabId: string; left: number; top: number }) {
  const request = usePage(tabId, (p) => p.permission);
  const guard = usePromptInputGuard(request?.id);
  if (!request) return null;
  const { icons, question } = describePermission(request);
  return (
    <PromptPopover key={request.id} width={300} top={top} left={left} modal={false}>
      {nativeToolbarAvailable() ? (
        <NativePromptBody
          spec={{ inputProtectionKey: request.id, icons, title: question, message: "Click the lock to change this any time", buttons: [{ id: "deny", title: "Don't Allow" }, { id: "accept", title: "Allow", primary: true }] }}
          onButton={guard((id: string) => answerPermission(tabId, request.id, id as "deny" | "accept"))}
          onClose={guard(() => answerPermission(tabId, request.id, "dismiss"))}
        />
      ) : (
      <View>
        <PromptBody icons={icons} title={question} message="Click the lock to change this any time">
          <PromptButton title="Don't Allow" onPress={guard(() => answerPermission(tabId, request.id, "deny"))} />
          <PromptButton title="Allow" primary onPress={guard(() => answerPermission(tabId, request.id, "accept"))} />
        </PromptBody>
        <PanelCloseButton onPress={guard(() => answerPermission(tabId, request.id, "dismiss"))} />
      </View>
      )}
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
  const theme = useTheme();
  const popups = usePage(tabId, (p) => p.popups);
  if (!popups.length) return null;
  const origin = popups[0]!.origin;
  const site = hostOf(origin);
  const close = () => answerBlockedPopups(tabId, "dismiss");
  const answer = (id: string) => answerBlockedPopups(tabId, id as BlockedPopupsAnswer);
  const openOne = (id: string) => openOneBlockedPopup(tabId, id);
  if (nativePromptFrames())
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
  return (
    <Popover width={BLOCKED_POPUPS_WIDTH} top={top} right={right} left={left} onDismiss={close}>
      <View style={{ paddingBottom: PANEL.listPadding }}>
        {nativeToolbarAvailable() ? (
          <NativePromptBody
            spec={{
              icons: ["macwindow.badge.plus"],
              title: `Always allow pop-ups from ${site}?`,
              message: `Allow ${site} to always open pop-up windows, choose every time, or always deny pop-ups.`,
              buttons: [{ id: "deny", title: "Always Deny" }, { id: "once", title: "Only Once" }, { id: "allow", title: "Always Allow", primary: true }],
              close: false,
            }}
            onButton={answer}
          />
        ) : (
        <PromptBody
          icons={["macwindow.badge.plus"]}
          title={`Always allow pop-ups from ${site}?`}
          message={`Allow ${site} to always open pop-up windows, choose every time, or always deny pop-ups.`}
        >
          <PromptButton title="Always Deny" onPress={() => answer("deny")} />
          <PromptButton title="Only Once" onPress={() => answer("once")} />
          <PromptButton title="Always Allow" primary onPress={() => answer("allow")} />
        </PromptBody>
        )}
        <PopoverSeparator />
        {popups.slice(-5).map((p) => (
          <PopoverRow
            key={p.id}
            icon="arrow.up.forward.app"
            title={p.url.replace(/^https?:\/\//, "") || "about:blank"}
            onPress={() => openOne(p.id)}
          />
        ))}
        {popups.length > 5 ? <Text style={{ fontSize: 11, color: theme.textSecondary, paddingLeft: PANEL.textColumn, paddingTop: 2 }}>{`and ${popups.length - 5} more`}</Text> : null}
      </View>
    </Popover>
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
  const theme = useTheme();
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
  const well = theme.dark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.04)";
  const choices = update && prompt.usernames.length > 1 ? prompt.usernames : [];
  return (
    <PromptPopover key={`${prompt.origin}|${prompt.username}|${prompt.state}`} width={update ? 310 : 350} top={top} right={right} modal={false}>
      {nativeToolbarAvailable() ? (
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
      ) : (
      <View>
        <PromptBody
          icons={["key.fill"]}
          title={update ? "Update saved password?" : `Save password for ${site}?`}
          message={update ? `It will be auto-filled on ${site}` : "That way, it'll be auto-filled next time"}
          detail={
            choices.length ? (
              <View style={{ borderRadius: 8, paddingVertical: 3, backgroundColor: well }}>
                {choices.map((name) => (
                  <UsernameChoice key={name} name={name} selected={name === username} onPress={() => setChosen(name)} />
                ))}
              </View>
            ) : (
              <View style={{ borderRadius: 8, paddingHorizontal: 10, paddingVertical: 8, gap: 3, backgroundColor: well }}>
                <Text numberOfLines={1} style={{ fontSize: 12, fontWeight: "500", color: theme.textPrimary }}>
                  {username || (prompt.federation ? `Signed in with ${hostOf(prompt.federation)}` : "No username")}
                </Text>
                {prompt.passwordLength > 0 && (
                  <Text numberOfLines={1} style={{ fontSize: 12, letterSpacing: 1, color: theme.textSecondary }}>
                    {"•".repeat(Math.min(prompt.passwordLength, 16))}
                  </Text>
                )}
              </View>
            )
          }
        >
          {!update && <PromptButton title="Never on This Site" onPress={() => answer("never")} />}
          <PromptButton title="Not Now" onPress={() => answer(update ? "nope" : "dismiss")} />
          <PromptButton title={update ? "Update" : "Save"} primary onPress={() => answer(update ? "update" : "save")} />
        </PromptBody>
        <PanelCloseButton onPress={() => answer("dismiss")} />
      </View>
      )}
    </PromptPopover>
  );
}

export function showAutofillPrompt(tabId: string, prompt: ChromeAutofillPrompt | null, id: number) {
  if (prompt) patchPage(tabId, { autofillPrompt: prompt });
  else if (pageOf(tabId).autofillPrompt?.id === id) patchPage(tabId, { autofillPrompt: null });
}

export function AutofillPrompt({ tabId, right, top }: { tabId: string; right: number; top: number }) {
  const theme = useTheme();
  const prompt = usePage(tabId, (p) => p.autofillPrompt);
  const guard = usePromptInputGuard(prompt?.id);
  if (!prompt) return null;
  const answer = guard((action: AutofillPromptAnswer) => {
    void webviews.get(tabId)?.resolveAutofillPrompt(prompt.id, action);
    patchPage(tabId, { autofillPrompt: null });
  });
  const well = theme.dark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.04)";
  const changes = prompt.changes ?? [];
  const values = (key: "to" | "from") => changes.filter((c) => c[key]).map((c) => c[key]);
  const section = (lines: string[], label?: string) => (
    <View key={label ?? "lines"} style={{ gap: 3 }}>
      {label ? <Text style={{ fontSize: 11, color: theme.textSecondary }}>{label}</Text> : null}
      {lines.map((line, i) => (
        <Text key={i} numberOfLines={2} style={{ fontSize: 12, fontWeight: i === 0 && !label ? "500" : "400", color: i === 0 || label ? theme.textPrimary : theme.textSecondary }}>
          {line}
        </Text>
      ))}
    </View>
  );
  const sections =
    prompt.kind !== "updateAddress"
      ? [section(prompt.lines)]
      : prompt.newLabel
        ? [section(values("to"), prompt.newLabel), section(values("from"), prompt.oldLabel)]
        : [section(values("to"))];
  return (
    <PromptPopover key={prompt.id} width={350} top={top} right={right} modal={false}>
      {nativeToolbarAvailable() ? (
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
      ) : (
      <View>
        <PromptBody
          icons={[prompt.kind === "saveCard" ? "creditcard.fill" : "mappin.and.ellipse"]}
          title={prompt.title}
          message={prompt.message || null}
          detail={
            <>
              <View style={{ borderRadius: 8, paddingHorizontal: 10, paddingVertical: 8, gap: 8, backgroundColor: well }}>{sections}</View>
              {prompt.footer ? <Text style={{ fontSize: 11, color: theme.textSecondary }}>{prompt.footer}</Text> : null}
            </>
          }
        >
          <PromptButton title={prompt.decline} onPress={() => answer("decline")} />
          <PromptButton title={prompt.accept} primary onPress={() => answer("accept")} />
        </PromptBody>
        <PanelCloseButton onPress={() => answer("dismiss")} />
      </View>
      )}
    </PromptPopover>
  );
}

export function ExternalAppPrompt({ tabId, left, top }: { tabId: string; left: number; top: number }) {
  const theme = useTheme();
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
      {nativeToolbarAvailable() ? (
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
      ) : (
      <View>
        <PromptBody
          icons={request.icon ? [] : [request.app ? "app" : "questionmark.app.dashed"]}
          image={request.icon}
          title={request.title}
          message={request.message}
          detail={
            request.remember ? (
              <Pressable onPress={() => setAlwaysGuarded(!always)} style={{ flexDirection: "row", alignItems: "flex-start", gap: 7 }}>
                <View style={{ marginTop: 1 }}>
                  <Checkbox value={always} onChange={setAlwaysGuarded} />
                </View>
                <Text style={{ flex: 1, fontSize: 12, lineHeight: 16, color: theme.textPrimary }}>{request.remember}</Text>
              </Pressable>
            ) : undefined
          }
        >
          {request.app ? (
            <>
              <PromptButton title="Cancel" onPress={() => answer(false)} />
              <PromptButton title="Open" primary onPress={() => answer(true)} />
            </>
          ) : (
            <PromptButton title="OK" primary onPress={() => answer(false)} />
          )}
        </PromptBody>
        <PanelCloseButton onPress={() => answer(false)} />
      </View>
      )}
    </PromptPopover>
  );
}

export function answerExternalApp(tabId: string, open: boolean, remember = false) {
  const request = pageOf(tabId).externalApp;
  if (!request) return;
  patchPage(tabId, { externalApp: null });
  void resolveExternalApp(request.id, open, remember);
}

function UsernameChoice({ name, selected, onPress }: { name: string; selected: boolean; onPress: () => void }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  return (
    <View {...hoverProps}>
      <Pressable onPress={onPress}>
        <View style={{ height: 28, marginHorizontal: 3, paddingHorizontal: 7, borderRadius: 6, flexDirection: "row", alignItems: "center", gap: 6, backgroundColor: hovered ? theme.rowHover : undefined }}>
          {selected ? (
            <Symbol name="checkmark" size={10} weight="semibold" color={theme.textPrimary} style={{ width: 14, height: 14 }} />
          ) : (
            <View style={{ width: 14, height: 14 }} />
          )}
          <Text numberOfLines={1} style={{ flex: 1, fontSize: 12, color: theme.textPrimary }}>
            {name || "No username"}
          </Text>
        </View>
      </Pressable>
    </View>
  );
}
