# Serena MCP routing

Serena is an MCP server; it cannot be invoked from a shell. When `where-is.sh` classifies a query as `symbol`, the script's job is to format the canonical symbol path and tell **the model** (Claude) which MCP tools to call.

## The two tools you always pair

| Tool                                       | Purpose                                            |
| ------------------------------------------ | -------------------------------------------------- |
| `mcp__serena__find_symbol`                 | Locate the definition (file + line + body if asked) |
| `mcp__serena__find_referencing_symbols`    | Find every caller / importer / referencer          |

Always call both for "where is X / who uses X" questions — definition without callers is half the answer.

## Arg shape

### `find_symbol`

```json
{
  "name_path": "FirestoreMemoryClient",
  "include_body": false,
  "include_kinds": [5, 12]
}
```

- `name_path` accepts a single name (`Foo`) or a slash-separated path (`Foo/bar` = method `bar` on class `Foo`). The `where-is.sh` symbol-mode emits the normalized form for you.
- `include_body: false` keeps the response small — flip to true only if you need to read the symbol's source inline.
- `include_kinds` (optional) filters by LSP SymbolKind (5 = Class, 12 = Function, 6 = Method, 13 = Variable…). Omit unless you know which kind you want.

### `find_referencing_symbols`

```json
{
  "name_path": "FirestoreMemoryClient"
}
```

Returns every reference with surrounding-symbol context (the function or class containing the reference) — much better than grep, which only gives line context.

## When to call additional Serena tools

- **`get_symbols_overview`** — when the user asks "what's in this file" and points at a path. Returns the top-level symbol tree without reading the file body.
- **`search_for_pattern`** — when you have a regex but want results scoped by symbol context (e.g. "find every `JSON.parse` inside any function whose name contains `Memory`"). Slower than ripgrep; prefer it only for structural-aware regex.
- **`find_declaration` / `find_implementations`** — for interface → implementation traversal in TypeScript.

## Fallback path

If Serena is unavailable in the conversation (e.g. user hasn't enabled the MCP server), the script's `fallback_hits` field surfaces ripgrep-ranked definition-shaped matches. They're noisier than Serena but cover the basics. Tell the user "Serena MCP unavailable; using ripgrep fallback — accuracy may be lower for overloaded names."

## Anti-patterns

- **Don't** call `find_symbol` with `include_body: true` and dump the whole symbol into chat — read selectively.
- **Don't** call `mcp__serena__search_for_pattern` for a plain identifier. That's what `find_symbol` is for.
- **Don't** make four parallel Serena calls speculatively. Make the two paired calls, read the result, decide if more is needed.
