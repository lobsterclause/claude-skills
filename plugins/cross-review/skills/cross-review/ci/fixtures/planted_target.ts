// Drill target for cross-review/ci/planted_round.sh (#116).
//
// This file is never imported or executed. It exists so a repository with no
// TypeScript/JavaScript of its own (this one) still has something for the
// weekly planted-mutation round to mutate: every operator in
// references/mutation_operators.json has at least one matching line below,
// so the seeded draw can land on any class. Keep the shapes; do not "fix"
// the deliberately plain code.
import path from "path";

export function pickName(explicit: string | undefined, fallback: string): string {
  return explicit ?? fallback;
}

export function withinBudget(spent: number, limit: number): boolean {
  return spent < limit && limit > 0;
}

async function warmUp(): Promise<void> {
  return;
}

export async function loadAll(loader: () => Promise<string[]>): Promise<string[]> {
  await warmUp();
  const rows = await loader();
  return rows;
}

export function firstOrNull(rows: string[] | null): string | null {
  if (rows == null) return null;
  return rows.length === 0 ? null : rows[0];
}

export function resolveUnder(root: string, name: string): string {
  return path.join(root, name);
}

export function guard(req: { auth(scope: string): boolean }): boolean {
  return req.auth("read");
}

function combine(left: string, right: string): string {
  return left + right;
}

export function combineNames(left: string, right: string): string {
  return combine(left, right);
}
