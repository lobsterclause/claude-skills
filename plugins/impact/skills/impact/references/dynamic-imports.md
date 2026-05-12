# Dynamic imports and other invisible edges

Static analysis can only see edges expressed as syntactic `import` / `require` with a literal string. The following are runtime-only and won't appear in the graph:

- `import(someVariable)` — the target is unknown until runtime.
- `require(\`./locales/\${lang}\`)` — string-template specifiers.
- File-based routing (Next.js `app/page.tsx`, Expo Router, Remix routes, SvelteKit `+page.svelte`) — the framework imports these by convention, not by `import` statement.
- DI containers / service registries that name modules by string ID.
- `eval`, `Function(\"...\")`, and other runtime code-gen.
- Webpack `require.context()` with regex.
- Workers loaded by URL: `new Worker(new URL(\"./worker.ts\", import.meta.url))` — modern bundlers track these, but the skill's tools don't follow them through to the worker's own imports.

## How the skill surfaces this

`impact.sh` runs a cheap regex sniff (`\\bimport\\s*\\(`) over the entry files and emits `N dynamic import() call(s) detected` in the Caveats section. This is a hint, not a precise count of unresolved edges — it includes literal `import("./a")` (which the graph *does* resolve).

For a precise audit, lean on `dependency-cruiser`'s `dynamic` flag on each dependency record. With the recommended config from `install.md`, those edges are still in the graph but tagged. You can grep them out of the raw `.impact-cache/graph.raw.json`:

```bash
node -e '
  const g = require("./.impact-cache/graph.raw.json");
  for (const m of g.modules) {
    for (const d of m.dependencies) if (d.dynamic) console.log(m.source, "->", d.resolved || d.module);
  }
'
```

## A dependency-cruiser rule to forbid hard-to-trace dynamic imports

If you want to actively prevent new dynamic imports in code paths the skill must reason about, add this to `.dependency-cruiser.cjs#forbidden`:

```js
{
  name: "no-dynamic-imports-in-core",
  severity: "warn",
  comment: "Dynamic imports break static impact analysis. Use a literal specifier or document the call site.",
  from: { path: "^packages/shared/lib/" },
  to:   { dynamic: true },
}
```

This won't break the build but will surface in `depcruise --validate` runs.

## Mitigations when you must rely on dynamic loading

1. **Keep a registry file** that explicitly imports every dynamically-loaded module. The skill picks up the registry's static edges; the dynamic site uses the registry. Trades runtime cost for analyzability.
2. **Document conventions** — e.g., "every route file under `apps/web/src/routes/**` is auto-loaded; treat changes to that tree as broadly impactful." When the skill reports few rev-deps for a routes file, the user should know that's expected.
3. **Hand-list affected tests** for changes in framework-route directories. The skill's "Affected test files" section will under-report there.
