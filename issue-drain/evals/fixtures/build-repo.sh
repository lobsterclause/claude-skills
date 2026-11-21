#!/bin/bash
# build-repo.sh <dest> — build the small git repo the triage evals and the
# script tests read. Dates are fixed, so `git blame` gives the same answer on
# every machine.
#
# History (the fixture issues are all "opened" on 2026-10-01):
#   2026-09-01  init                      everything below, with its bugs
#   2026-10-15  fix(auth) (#12)           clears the badge on logout   -> issue 101 is fixed
#   2026-10-20  fix(ui) (#14)             stacks toasts                -> issue 102 looks fixed (visual)
# The branch is `develop`; the scripts are pointed at it with --ref develop.
set -euo pipefail
dest="${1:?usage: build-repo.sh <dest>}"
[ ! -e "$dest/.git" ] || { echo "build-repo.sh: $dest is already a repo" >&2; exit 2; }
mkdir -p "$dest"
cd "$dest"
git init -q -b develop
git config user.name "Fixture"
git config user.email "fixture@example.invalid"
git config commit.gpgsign false

commit() { # commit <iso date> <message>
  git add -A
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -q -m "$2"
}

mkdir -p src/auth src/lib src/timer src/list src/crisis src/ui src/search src/settings .github/workflows

cat > README.md <<'EOF'
# tidepool

A small fixture app: sessions, a countdown, a paged list, toasts and a search box.
EOF

cat > src/auth/session.ts <<'EOF'
import { badge } from "../ui/badge";

export interface Session {
  userId: string;
  token: string;
}

let current: Session | null = null;

export function login(session: Session): void {
  current = session;
}

export function logout(): void {
  current = null;
}

export function currentSession(): Session | null {
  return current;
}
EOF

cat > src/lib/format.ts <<'EOF'
/** Formats a duration as m:ss, zero-padding the seconds. */
export function formatDuration(ms: number): string {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}
EOF

cat > src/lib/clamp.ts <<'EOF'
/** Clamps n into [min, max]. Empty or non-numeric input falls back to min. */
export function clamp(n: number, min: number, max: number): number {
  if (Number.isNaN(n)) return min;
  if (n < min) return min;
  if (n > max) return max;
  return n;
}
EOF

# A line with backslashes: a quote of it must survive the trip through the shell and awk.
cat > src/lib/words.ts <<'EOF'
export const WORD = /\w+\s*/g;
EOF

cat > src/timer/countdown.ts <<'EOF'
export function countdownLabel(remainingMs: number): string {
  const totalSeconds = Math.floor(remainingMs / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return minutes + ":" + seconds;
}
EOF

cat > src/list/paginate.ts <<'EOF'
export interface Page<T> {
  items: T[];
  index: number;
}

/** Number of pages needed to show `total` items, `size` per page. */
export function pageCount(total: number, size: number): number {
  return Math.floor(total / size) + 1;
}

export function pageOf<T>(all: T[], index: number, size: number): Page<T> {
  const start = index * size;
  return { items: all.slice(start, start + size), index };
}
EOF

cat > src/list/render.ts <<'EOF'
import { pageCount, pageOf } from "./paginate";

export function renderPager(total: number, size: number): string {
  const pages = pageCount(total, size);
  return Array.from({ length: pages }, (_, i) => `[${i + 1}]`).join(" ");
}

export function renderLastPage<T>(all: T[], size: number): T[] {
  const last = pageCount(all.length, size) - 1;
  return pageOf(all, last, size).items;
}
EOF

cat > src/crisis/keywords.ts <<'EOF'
const PHRASES = ["i can't go on", "i don't want to be here"];

/** True when the message contains a crisis phrase. */
export function matchesCrisisPhrase(message: string): boolean {
  const text = message.toLowerCase();
  return PHRASES.some((phrase) => text.includes(phrase));
}
EOF

cat > src/ui/badge.ts <<'EOF'
let count = 0;

export const badge = {
  increment(): void {
    count += 1;
  },
  reset(): void {
    count = 0;
  },
  value(): number {
    return count;
  },
};
EOF

cat > src/ui/toast.tsx <<'EOF'
export interface Toast {
  id: string;
  text: string;
}

export function toastStyle(index: number): Record<string, string> {
  return { position: "fixed", bottom: "16px", right: "16px" };
}
EOF

cat > src/search/box.ts <<'EOF'
export function onSearchInput(input: HTMLInputElement, render: () => void): void {
  input.addEventListener("input", () => {
    render();
    input.blur();
  });
}
EOF

cat > src/settings/theme.ts <<'EOF'
export type Theme = "light";

export function currentTheme(): Theme {
  return "light";
}
EOF

cat > .github/workflows/ci.yml <<'EOF'
name: ci
on: [pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/cache@v4
        with:
          path: ~/.cache/yarn
          key: deps-${{ hashFiles('pnpm-lock.yaml') }}
      - run: pnpm install --frozen-lockfile
      - run: pnpm test
EOF

commit "2026-09-01T12:00:00Z" "init: tidepool fixture"

cat > src/auth/session.ts <<'EOF'
import { badge } from "../ui/badge";

export interface Session {
  userId: string;
  token: string;
}

let current: Session | null = null;

export function login(session: Session): void {
  current = session;
}

export function logout(): void {
  current = null;
  badge.reset();
}

export function currentSession(): Session | null {
  return current;
}
EOF
commit "2026-10-15T12:00:00Z" "fix(auth): clear the badge count on logout (#12)"

cat > src/ui/toast.tsx <<'EOF'
export interface Toast {
  id: string;
  text: string;
}

export function toastStyle(index: number): Record<string, string> {
  return { position: "fixed", bottom: `${16 + index * 56}px`, right: "16px" };
}
EOF
commit "2026-10-20T12:00:00Z" "fix(ui): stack toasts instead of overlapping (#14)"
