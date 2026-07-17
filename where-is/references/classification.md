# Classification heuristics

The classifier (`scripts/classify.sh`) inspects the raw query and routes it to one of four kinds. First match wins.

## Flowchart

```
        ┌──────────────────────────────┐
        │ single token matching        │
        │ ^[A-Za-z_$][\w$]*(/[\w$]+)*$ │──────► symbol   (Serena MCP)
        └─────────────┬────────────────┘
                      │ no
                      ▼
        ┌─────────────────────────────┐
        │ contains '/', '*', '?', '[' │
        │ OR ends in .ts/.tsx/.js/... │──────► path
        └─────────────┬───────────────┘
                      │ no
                      ▼
        ┌──────────────────────────────┐
        │ contains '$$$', '$<name>',   │
        │ '=>', 'as any', '(' or '<'   │──────► pattern  (ast-grep)
        └─────────────┬────────────────┘
                      │ no
                      ▼
                  ─────►  concept  (ripgrep)
```

Symbol is checked first: a slash-joined `Class/method` query (Serena's `name_path` form) matches the symbol shape and would otherwise be shadowed by the path rule below it. See "False-positive guards" for the trade-off this makes.

## Edge cases

| Query                              | Kind     | Why                              |
| ---------------------------------- | -------- | -------------------------------- |
| `FirestoreMemoryClient`            | symbol   | Single PascalCase identifier     |
| `useResources`                     | symbol   | Single camelCase identifier      |
| `FirestoreMemoryClient/storeMemory`| symbol   | Class/method form (Serena `name_path`) |
| `useEffect($$$)`                   | pattern  | `$$$` is ast-grep metavar        |
| `useState<$T>($V)`                 | pattern  | Angle brackets + metavar         |
| `as any`                           | pattern  | Pattern marker token             |
| `apps/web/src/pages`               | path     | Contains `/`                     |
| `*.test.ts`                        | path     | Glob char + extension            |
| `useResources.ts`                  | path     | Code extension                   |
| `login flow`                       | concept  | Two-plus words, lowercase phrase |
| `what file handles auth`          | concept  | Natural language                 |

## Overrides

Pass `--kind <symbol|pattern|path|concept>` to bypass the classifier. Useful when:

- The user asked for `useEffect` but means *the symbol named useEffect*, not the pattern → `--kind symbol useEffect`.
- A symbol-looking name happens to collide with a literal pattern token.

## False-positive guards

- Queries with embedded spaces and **also** containing a `/` are still classified as `path` — most monorepo paths have multiple slashes; an English sentence is unlikely to use them.
- Class/method form `Foo/bar` also matches the path heuristic (contains `/`), but the classifier checks **symbol first**, so it correctly stays `symbol` (the Serena `name_path` form). An ordinary extension-less directory path (`apps/mobile/hooks`) is the false-positive trade this makes — it also matches the symbol shape, so a Serena lookup on it misses and self-corrects, rather than the more common case (a real path) needing `--kind symbol` on every call. Pass `--kind path` explicitly if you hit that edge case.

## When the model should pre-classify

If the user's intent is obvious from context (they said "find the file at apps/web/src/X.ts"), the model can skip `classify.sh` and call `where-is.sh --kind path apps/web/src/X.ts` directly. The classifier is a fallback for ambiguous queries.
