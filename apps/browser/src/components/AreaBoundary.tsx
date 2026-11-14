import { onHostedEvent, SolaraHostedView } from "@solara/settings";
import { Component, Fragment, useEffect, useState, type ContextType, type ReactNode } from "react";
import { recordJsError } from "../lib/jsErrors";
import { ThemeScope, useTheme } from "../lib/theme";
import { WindowContext } from "../store/hooks";

const AUTO_RETRIES = 2;
const RETRY_DELAYS_MS = [300, 1200];
const CALM_AFTER_MS = 60_000;

type Props = { area: string; windowId?: string; quiet?: boolean; children: ReactNode };
type State = { error: Error | null; mount: number; retries: number; lastErrorAt: number };

const debugBoundaries = __DEV__ ? new Set<AreaBoundary>() : null;
let recoverySequence = 0;

export class AreaBoundary extends Component<Props, State> {
  static contextType = WindowContext;
  state: State = { error: null, mount: 0, retries: 0, lastErrorAt: 0 };
  private retryTimer: ReturnType<typeof setTimeout> | undefined;
  private fixtureError: Error | null = null;
  private fixturePlain = false;

  get windowId() { return this.props.windowId ?? (this.context as ContextType<typeof WindowContext>) ?? ""; }

  componentDidMount() {
    debugBoundaries?.add(this);
  }

  debugFail(plain: boolean) {
    if (!__DEV__) return;
    this.fixtureError = new Error("Forced area recovery fixture");
    this.fixtureError.stack = "AreaRecoveryFixture";
    this.fixturePlain = plain;
    clearTimeout(this.retryTimer);
    this.setState({ error: null, retries: 0, lastErrorAt: 0 });
  }

  debugRecover() {
    if (__DEV__) this.reload();
  }

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error) {
    recordJsError(error, "render", this.props.area);
    if (__DEV__) (globalThis as { __lastRenderError?: string }).__lastRenderError = `${error.message}\n${error.stack ?? ""}`;
    const now = Date.now();
    const retries = now - this.state.lastErrorAt > CALM_AFTER_MS ? 0 : this.state.retries;
    this.setState({ retries, lastErrorAt: now });
    if (retries >= AUTO_RETRIES) return;
    clearTimeout(this.retryTimer);
    this.retryTimer = setTimeout(() => this.remount(retries + 1), RETRY_DELAYS_MS[retries] ?? RETRY_DELAYS_MS.at(-1));
  }

  componentWillUnmount() {
    debugBoundaries?.delete(this);
    clearTimeout(this.retryTimer);
  }

  private remount(retries: number) {
    this.setState((s) => ({ error: null, mount: s.mount + 1, retries }));
  }

  private reload = () => {
    this.fixtureError = null;
    this.fixturePlain = false;
    this.remount(0);
  };

  render() {
    if (!this.state.error) return <Fragment key={this.state.mount}>{__DEV__ && this.fixtureError ? <AreaFixtureFailure error={this.fixtureError} /> : this.props.children}</Fragment>;
    if (this.state.retries < AUTO_RETRIES || this.props.quiet) return null;
    const fill = this.props.area === "window";
    const row = <AreaErrorRow fill={fill} windowId={this.windowId} detail={__DEV__ ? this.state.error : null} forcePlain={__DEV__ && this.fixturePlain} onReload={this.reload} />;
    return (
      <PlainFallback fill={fill} windowId={this.windowId} onReload={this.reload}>
        {this.props.windowId ? (
          <WindowContext.Provider value={this.props.windowId}>
            <ThemeScope>{row}</ThemeScope>
          </WindowContext.Provider>
        ) : (
          row
        )}
      </PlainFallback>
    );
  }
}

export class PlainFallback extends Component<{ fill: boolean; windowId: string; onReload: () => void; children: ReactNode }, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  componentDidCatch(error: Error) {
    recordJsError(error, "render", "error row");
  }

  render() {
    if (!this.state.failed) return this.props.children;
    return <NativeAreaRecovery fill={this.props.fill} windowId={this.props.windowId} plain onReload={this.props.onReload} textPrimary="#8e8e93" textSecondary="#8e8e93" />;
  }
}

export function NativeAreaRecovery({ fill, windowId, plain = false, detail = null, onReload, textPrimary, textSecondary }: {
  fill: boolean;
  windowId: string;
  plain?: boolean;
  detail?: Error | null;
  onReload: () => void;
  textPrimary: string;
  textSecondary: string;
}) {
  const [recoveryId] = useState(() => `area-recovery-${++recoverySequence}`);
  const [height, setHeight] = useState(38);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    const stop = onHostedEvent("areaRecovery", windowId, (name, payload) => {
      if (payload.recoveryId !== recoveryId) return;
      if (name === "reload") onReload();
      else if (name === "height" && typeof payload.height === "number" && Number.isFinite(payload.height) && payload.height > 0) setHeight(payload.height);
    });
    setReady(true);
    return stop;
  }, [windowId, recoveryId, onReload]);
  if (!ready) return null;
  return <SolaraHostedView
    kind="areaRecovery"
    windowId={windowId}
    state={JSON.stringify({ recoveryId, fill, plain, textPrimary, textSecondary, ...(__DEV__ && detail ? { detail: `${detail.message}\n\n${detail.stack ?? ""}` } : {}) })}
    style={fill ? { flex: 1 } : { height }}
  />;
}

export function AreaErrorRow({ fill, windowId, detail, forcePlain = false, onReload }: { fill: boolean; windowId: string; detail: Error | null; forcePlain?: boolean; onReload: () => void }) {
  const theme = useTheme();
  if (__DEV__ && forcePlain) throw new Error("Forced area recovery theme failure");
  return <NativeAreaRecovery fill={fill} windowId={windowId} detail={detail} onReload={onReload} textPrimary={theme.textPrimary} textSecondary={theme.textSecondary} />;
}

function AreaFixtureFailure({ error }: { error: Error }): never {
  throw error;
}

if (__DEV__) (globalThis as { acAreaRecovery?: unknown }).acAreaRecovery = {
  fail(area: string, windowId: string, plain = false) {
    const matches = Array.from(debugBoundaries ?? []).filter(boundary => boundary.props.area === area && boundary.windowId === windowId);
    for (const boundary of matches) boundary.debugFail(plain);
    return matches.length;
  },
  recover(area: string, windowId: string) {
    const matches = Array.from(debugBoundaries ?? []).filter(boundary => boundary.props.area === area && boundary.windowId === windowId);
    for (const boundary of matches) boundary.debugRecover();
    return matches.length;
  },
  boundaries() {
    return Array.from(debugBoundaries ?? []).map(boundary => ({ area: boundary.props.area, windowId: boundary.windowId, retries: boundary.state.retries, failed: !!boundary.state.error, quiet: !!boundary.props.quiet }));
  },
};
