# Output format reference

Examples of each kind's output, both pretty and JSON.

## symbol

Pretty:

```
== Symbol: FirestoreMemoryClient ==
ROUTE: Serena MCP (call from this conversation)
  1. mcp__serena__find_symbol            name_path="FirestoreMemoryClient"  include_body=false
  2. mcp__serena__find_referencing_symbols  name_path="FirestoreMemoryClient"

== Fallback (ripgrep, definition-shaped matches) ==
  [@kindred-mama/shared] packages/shared/lib/memory/FirestoreMemoryClient.ts:42:export class FirestoreMemoryClient implements MemoryClient {
```

JSON:

```json
{
  "kind": "symbol",
  "query": "FirestoreMemoryClient",
  "normalized": "FirestoreMemoryClient",
  "route": "serena-mcp",
  "next_actions": [
    { "tool": "mcp__serena__find_symbol", "args": { "name_path": "FirestoreMemoryClient", "include_body": false } },
    { "tool": "mcp__serena__find_referencing_symbols", "args": { "name_path": "FirestoreMemoryClient" } }
  ],
  "fallback_hits": [
    { "file": "packages/shared/lib/memory/FirestoreMemoryClient.ts", "line": 42, "snippet": "export class FirestoreMemoryClient ...", "package": "@kindred-mama/shared" }
  ]
}
```

## pattern

Pretty:

```
== Pattern: useEffect($$$) ==
ROUTE: ast-grep
apps/web/src/components/Foo.tsx
12│  useEffect(() => { ... }, [])
...
```

JSON contains `route: "ast-grep"` and a `matches` blob with the raw tool output.

## path

Pretty:

```
== Path: apps/web/src/pages/Resources ==
ROUTE: git ls-files / fs walk
  [@kindred-mama/web] apps/web/src/pages/Resources/index.tsx
  [@kindred-mama/web] apps/web/src/pages/Resources/ResourcesPage.tsx
```

JSON:

```json
{
  "kind": "path",
  "route": "fs-walk",
  "files": [
    { "file": "apps/web/src/pages/Resources/index.tsx", "package": "@kindred-mama/web" }
  ]
}
```

## concept

Pretty:

```
== Concept: login flow ==
ROUTE: ripgrep (best-effort; re-phrase as symbol or path if noisy)
  [@kindred-mama/web] apps/web/src/pages/Login.tsx:23:export function LoginPage() {
  [@kindred-mama/shared] packages/shared/lib/auth/loginFlow.ts:11:export async function runLoginFlow(...)
```

JSON contains `route: "ripgrep"` and `hits: [{ file, line, snippet, package }]`.

## Sorting / ranking

- **symbol fallback**: definition-shaped matches first, then literal matches. Capped at 20 hits.
- **pattern**: ast-grep's native order. Capped at 60 lines.
- **path**: alphabetical by file path within each package group.
- **concept**: ripgrep's native order (file order, line order). Capped at 30 hits.

Increase caps only when piping with `--json` to a downstream consumer.
