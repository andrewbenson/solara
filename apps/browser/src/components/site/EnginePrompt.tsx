import { useState } from "react";
import { acceptEngineOffer, stayOnPage, useEngineOffers, type EngineOffer } from "../../lib/engines";
import { PRODUCT } from "../../lib/productName";
import { NativePromptBody, PromptPopover } from "./NativePromptBody";

export function EngineOfferPrompt({ tabId, left, top }: { tabId: string; left: number; top: number }) {
  const offer = useEngineOffers((offers) => offers[tabId]);
  return offer ? <OfferPopover key={offer.site} tabId={tabId} offer={offer} left={left} top={top} /> : null;
}

function OfferPopover({ tabId, offer, left, top }: { tabId: string; offer: EngineOffer; left: number; top: number }) {
  const [remember, setRemember] = useState(false);
  return (
    <PromptPopover width={320} top={top} left={left} modal={false}>
      <NativePromptBody
        spec={{
          icons: ["play.circle.fill", "safari"],
          title: `Play ${offer.host} in WebKit?`,
          message: `This site plays protected video, which Chromium in ${PRODUCT} can't. The page reloads in WebKit, which keeps its own sign-ins.`,
          details: offer.canRemember ? [{ kind: "checkbox", label: "Don't ask again for this site", value: remember }] : [],
          buttons: [{ id: "stay", title: "Stay on Page" }, { id: "webkit", title: "Open in WebKit", primary: true }],
        }}
        onButton={(id) => (id === "stay" ? stayOnPage(tabId, remember) : void acceptEngineOffer(tabId))}
        onToggle={setRemember}
        onClose={() => stayOnPage(tabId)}
      />
    </PromptPopover>
  );
}
