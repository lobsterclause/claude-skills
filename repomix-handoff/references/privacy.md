# Privacy: what gets packed and how to scrub it

A repomix snapshot is **raw source code** and any text files in the included paths. Treat it like an outgoing email containing your repo.

## What is included by default

- Every file matching the computed `--include` set (PR-scoped diff, or your explicit `--paths`).
- Files are bundled verbatim — comments, strings, hard-coded constants, debug logs all included.

## What is excluded by default

The skill's default exclude list (see `scripts/compute_scope.sh`):

- `node_modules`, `dist`, `.next`, `coverage`, `build`, `.turbo`, `.cache`
- Lockfiles: `*.lock`, `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`
- Build artifacts: `*.min.js`, `*.map`
- Binary assets: `*.png`, `*.jpg`, `*.jpeg`, `*.gif`, `*.webp`, `*.pdf`, `*.mp4`, `*.webm`
- VCS / OS noise: `.git/**`, `**/.DS_Store`
- Snapshots: `**/__snapshots__/**`
- Tests (unless `--include-tests`): `*.test.*`, `*.spec.*`, `__tests__/`, `e2e/`

## What is NOT excluded by default

These you must scrub or add to `--exclude` yourself:

- **`.env`, `.env.*`** — Treated as plain text. Add `--exclude ".env*,**/.env*"` if your branch touches them.
- **Hardcoded API keys / tokens** in source. The skill does **not** scan content for secrets. Use a dedicated tool (`trufflehog`, `gitleaks`) before packing if you're unsure.
- **Customer PII fixtures** — JSON test fixtures with real user data.
- **Internal URLs, hostnames, customer names** — These survive packing.

## Recommended scrub workflow before sending externally

```bash
# 1. Sanity check for secrets in the slice you intend to pack:
git diff --name-only origin/main...HEAD | xargs grep -lE "(API_KEY|SECRET|TOKEN|PRIVATE_KEY|BEGIN.*PRIVATE)" || echo "no obvious secrets"

# 2. Pack with extra excludes for env / fixture files:
./scripts/handoff.sh --exclude ".env*,**/.env*,**/fixtures/customer*.json"

# 3. Spot-check the snapshot:
grep -E "(API_KEY|SECRET|TOKEN)" /tmp/repomix-handoff-*.md || echo "clean"
```

## Third-party CLI Terms of Service

Once a snapshot leaves your machine, it is subject to the receiving CLI's data-handling policy:

- **codex CLI (OpenAI)** — Subject to OpenAI's API data policy. By default, API submissions are not used for training; consult current policy.
- **gemini CLI (Google)** — Subject to Google's Gemini API terms. Default-off training on free-tier varies — check current policy.
- **kimi CLI (Moonshot)** — Subject to Moonshot's terms. Less mature documentation; verify before sending anything sensitive.
- **claude CLI (Anthropic)** — Subject to Anthropic's API terms.

**Never** paste a snapshot into a public pastebin, public chat, or a free web tool with unknown data-handling.

## Per-user PII / clinical data caveat (project-specific)

For projects handling clinical, therapeutic, or other regulated user data (HIPAA, GDPR, CCPA, WA MHMDA):

- Do not include user-message fixtures, real conversation logs, or memory-extraction outputs in a snapshot intended for an external CLI without explicit DPA coverage.
- Per-user encryption metadata (DEK derivation, KMS resource IDs) is sensitive; exclude `**/keys/**`, `**/secrets/**`, `**/kms/**` if those paths exist.

When in doubt: ship a smaller `--paths` slice and skip anything that looks like real user data.
