# Install

## Auto-install (default behavior)

You usually don't need to do this yourself. When `build_graph.sh` finds neither tool and the target repo has a `package.json`, it installs `dependency-cruiser` as a devDependency automatically — detecting pnpm/yarn/npm from the repo's lockfile, same commands as below — and prints what it did to stderr. Opt out with `IMPACT_NO_AUTO_INSTALL=1`.

## Manual install

`dependency-cruiser` alone is enough — it's `detect_tools.sh`'s preferred tool whenever both are present, so adding `madge` too is redundant unless you specifically want it as an independent cross-check.

```bash
# pnpm workspace root
pnpm add -D -w dependency-cruiser

# npm
npm i -D dependency-cruiser

# yarn (classic)
yarn add -D -W dependency-cruiser
```

Add `madge` alongside it only if you want both tools installed for comparison — `dependency-cruiser` wins the preference either way:

```bash
pnpm add -D -w madge dependency-cruiser   # pnpm
npm i -D madge dependency-cruiser         # npm
yarn add -D -W madge dependency-cruiser   # yarn (classic)
```

## Minimum dependency-cruiser config

Drop a `.dependency-cruiser.cjs` at the repo root. The skill will pick it up automatically.

```js
// .dependency-cruiser.cjs — minimum useful config for /impact
module.exports = {
  options: {
    tsConfig: { fileName: "tsconfig.json" },
    tsPreCompilationDeps: true,           // surface type-only edges
    exclude: {
      path: "(^|/)(node_modules|dist|build|\\.next|coverage|\\.impact-cache)(/|$)",
    },
    doNotFollow: { path: "node_modules" },
    reporterOptions: {
      json: { exclude: { path: "node_modules" } },
    },
  },
  forbidden: [
    // Optional rules — surfaced as warnings in the graph but not required by /impact.
    {
      name: "no-circular",
      severity: "warn",
      from: {},
      to: { circular: true },
    },
  ],
};
```

## Minimum madge config

`madge` reads `tsconfig.json` automatically when you pass `--ts-config`. No separate config file required. If you have path aliases that madge mis-resolves, add a `.madgerc`:

```json
{
  "tsConfig": "./tsconfig.json",
  "fileExtensions": ["ts", "tsx", "js", "jsx", "mjs", "cjs"]
}
```

## Verifying the install

```bash
# Local install
./node_modules/.bin/depcruise --version
./node_modules/.bin/madge --version

# Or via the skill
bash ${CLAUDE_PLUGIN_ROOT}/skills/impact/scripts/detect_tools.sh
# => {"madge": true, "depcruiser": true, "preferred": "depcruiser"}
```

If `detect_tools.sh` reports `"preferred": "none"`, the skill will degrade to grep one-hop and emit a warning on stderr.
