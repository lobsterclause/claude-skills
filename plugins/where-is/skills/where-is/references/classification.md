# Classification heuristics

The classifier (`scripts/classify.sh`) inspects the raw query and routes it to one of four kinds. First match wins.

## Flowchart

```
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
        ┌──────────────────────────────┐
        │ single token matching        │
        │ ^[A-Za-z_$][\w$]*(/[\w$]+)*$ │──────► symbol   (Serena MCP)
        └─────────────┬────────────────┘
                      │ no
                      ▼
                  ─────►  concept  (ripgrep)
```

## Edge cases

| Query                              | Kind     | Why                              |
| ---------------------------------- | -------- | -------------------------------- |
| `FirestoreMemoryClient`            | symbol   | Single PascalCase identifier     |
| `useResources`                     | symbol   | Single camelCase identifier      |
| `FirestoreMemoryClient/storeMemory`| path     | Path rule wins on `/`; pass `--kind symbol` for the Serena `name_path` form |
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
- Class/method form `Foo/bar` collides with the path heuristic; the classifier checks the path rule **first**, so users wanting the Serena form must pass `--kind symbol`.

## When the model should pre-classify

If the user's intent is obvious from context (they said "find the file at apps/web/src/X.ts"), the model can skip `classify.sh` and call `where-is.sh --kind path apps/web/src/X.ts` directly. The classifier is a fallback for ambiguous queries.
