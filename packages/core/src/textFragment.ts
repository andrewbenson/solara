
export type TextFragment = { prefix?: string; start: string; end?: string; suffix?: string };

export type SelectionContext = {
  selected: string;
  before: string;
  after: string;
  pageText: string;
};

const MAX_EXACT_WORDS = 10;
const RANGE_WORDS = 3;
const MAX_CONTEXT_WORDS = 5;

const normalize = (s: string) => s.replace(/\s+/g, " ").trim();
const wordsOf = (s: string) => normalize(s).split(" ").filter(Boolean);

function repeats(haystack: string, needle: string): boolean {
  if (!needle) return false;
  const border = new Int32Array(needle.length);
  for (let i = 1, k = 0; i < needle.length; i++) {
    while (k > 0 && needle.charCodeAt(i) !== needle.charCodeAt(k)) k = border[k - 1]!;
    if (needle.charCodeAt(i) === needle.charCodeAt(k)) k++;
    border[i] = k;
  }
  let found = 0;
  for (let i = 0, k = 0; i < haystack.length; i++) {
    while (k > 0 && haystack.charCodeAt(i) !== needle.charCodeAt(k)) k = border[k - 1]!;
    if (haystack.charCodeAt(i) === needle.charCodeAt(k)) k++;
    if (k === needle.length) {
      if (++found === 2) return true;
      k = border[k - 1]!;
    }
  }
  return false;
}

const WORD = /^[\p{L}\p{N}_]$/u;
const WORD_START = /^[\p{L}\p{N}_]+/u;

function previousCodePoint(text: string, end: number): number {
  const last = text.charCodeAt(end - 1);
  const first = text.charCodeAt(end - 2);
  return last >= 0xdc00 && last <= 0xdfff && first >= 0xd800 && first <= 0xdbff ? end - 2 : end - 1;
}

function wordSuffix(text: string): string {
  let start = text.length;
  while (start > 0) {
    const previous = previousCodePoint(text, start);
    if (!WORD.test(text.slice(previous, start))) break;
    start = previous;
  }
  return text.slice(start);
}

function toWordBoundaries({ selected, before, after, pageText }: SelectionContext): SelectionContext {
  const head = WORD_START.test(selected) ? wordSuffix(before) : "";
  const tail = WORD.test(selected.slice(previousCodePoint(selected, selected.length))) ? (WORD_START.exec(after)?.[0] ?? "") : "";
  return {
    selected: head + selected + tail,
    before: before.slice(0, before.length - head.length),
    after: after.slice(tail.length),
    pageText,
  };
}

export function chooseTextFragment(context: SelectionContext): TextFragment | null {
  const { selected, before, after, pageText } = toWordBoundaries(context);
  const blocks = selected.split("\n").map(normalize).filter(Boolean);
  if (!blocks.length) return null;
  const page = normalize(pageText).toLowerCase();
  const repeated = (text: string) => repeats(page, text.toLowerCase());
  const all = blocks.flatMap(wordsOf);
  const beforeWords = wordsOf(before);
  const afterWords = wordsOf(after);

  if (blocks.length === 1 && all.length <= MAX_EXACT_WORDS) {
    const start = all.join(" ");
    if (!repeated(start)) return { start };
    for (let n = 1; ; n++) {
      const prefix = beforeWords.slice(-n).join(" ");
      const suffix = afterWords.slice(0, n).join(" ");
      const exhausted = n >= MAX_CONTEXT_WORDS || n >= Math.max(beforeWords.length, afterWords.length);
      if (exhausted || !repeated([prefix, start, suffix].filter(Boolean).join(" ")))
        return { ...(prefix && { prefix }), start, ...(suffix && { suffix }) };
    }
  }
  const first = wordsOf(blocks[0]!);
  const last = wordsOf(blocks[blocks.length - 1]!);
  const most = blocks.length === 1 ? Math.floor(all.length / 2) : Math.min(first.length, last.length);
  const opening = (words: number) => first.slice(0, words).join(" ");
  let n = Math.min(RANGE_WORDS, most);
  if (n < most && repeated(opening(n))) {
    let unique = most;
    while (n + 1 < unique) {
      const middle = (n + unique) >>> 1;
      if (repeated(opening(middle))) n = middle;
      else unique = middle;
    }
    n = unique;
  }
  const start = opening(n);
  const end = last.slice(-n).join(" ");
  if (!repeated(start) || !beforeWords.length) return { start, end };
  return { prefix: beforeWords.slice(-RANGE_WORDS).join(" "), start, end };
}

const encodeTerm = (s: string) => encodeURIComponent(s).replace(/-/g, "%2D");

function textDirective({ prefix, start, end, suffix }: TextFragment): string {
  const parts = [prefix && `${encodeTerm(prefix)}-`, encodeTerm(start), end && encodeTerm(end), suffix && `-${encodeTerm(suffix)}`];
  return `text=${parts.filter(Boolean).join(",")}`;
}

export function withTextFragment(url: string, fragment: TextFragment): string {
  const hash = url.indexOf("#");
  const base = hash === -1 ? url : url.slice(0, hash);
  let ref = hash === -1 ? "" : url.slice(hash + 1);
  const directive = ref.indexOf(":~:");
  if (directive !== -1) ref = ref.slice(0, directive);
  return `${base}#${ref}:~:${textDirective(fragment)}`;
}
