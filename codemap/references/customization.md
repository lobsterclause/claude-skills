# Customization

The codemap is intentionally minimal — six sections, no flags for layout. If
you need more, customize via one of these patterns.

## Add custom sections

Run `codemap.sh --json` to get the underlying model, then post-process:

```bash
bash scripts/codemap.sh --json > .codemap.json
# Render the standard markdown:
bash scripts/codemap.sh --output docs/architecture/codemap.md
# Append your own sections:
cat >> docs/architecture/codemap.md <<EOF

## Crisis-safety paths

- packages/shared/lib/clinical/
- functions/src/safety.ts
EOF
```

The header timestamp at the top stays correct; deterministic body keeps clean
diffs.

## Pin generation time (deterministic builds)

```bash
CODEMAP_FAKE_TIME=2026-05-12T00:00:00Z bash scripts/codemap.sh
```

Useful for reproducible builds, CI snapshots, and golden-file tests.

## Override the regen command shown in the footer

```bash
CODEMAP_REGEN_CMD="pnpm codemap" bash scripts/codemap.sh
```

The footer line becomes:

```
Regenerate with: `pnpm codemap`
```

## Trim external deps

```bash
bash scripts/codemap.sh --no-external           # remove the section entirely
bash scripts/codemap.sh --max-external 5        # top-5 instead of top-10
```

## Plug into pre-commit / CI

Because output is byte-stable on unchanged input (except for the header
timestamp), you can pin the timestamp and assert no diff:

```bash
CODEMAP_FAKE_TIME=fixed bash scripts/codemap.sh
git diff --exit-code docs/architecture/codemap.md \
  || { echo "codemap drift — refresh and commit"; exit 1; }
```

## Add ownership labels beyond the defaults

The "Conventions / ownership" section enumerates files. If you maintain a
ownership labels file (e.g. `docs/architecture/team-map.md`), it's already
picked up automatically because the script lists every `docs/architecture/*.md`
except `codemap.md` itself.
