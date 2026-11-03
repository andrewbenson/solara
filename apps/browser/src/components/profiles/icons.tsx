const SYMBOL_PREFIX = "symbol:";
export const profileSymbol = (icon: string | null) => (icon?.startsWith(SYMBOL_PREFIX) ? icon.slice(SYMBOL_PREFIX.length) : null);
