# Maestro — when to escalate to declarative flows

This skill is for **ad-hoc** control. Maestro is for **repeatable** flows.

## Rule of thumb

| Situation | Use |
| --- | --- |
| "Run the app, tap signup, screenshot" (one-off) | This skill |
| "Verify the whole onboarding flow in CI nightly" | Maestro |
| "Reproduce this bug by tapping these five things" | This skill |
| "Regression test for this bug going forward" | Maestro |
| "Debug what the app is doing right now" | This skill |
| "Prove the app still works before merging" | Maestro |

Use this skill to **explore** a flow, then **codify** it in Maestro once it's stable.

## Authoring a Maestro flow from a skill session

When a user asks you to convert an interactive session into a flow:

1. Review the session's screenshots and the sequence of `tap`/`input_text`/`deeplink` calls in the conversation.
2. For each interaction, prefer `id` (accessibility-id / React Native `testID`) over `text` matching. Text is brittle; accessibility ids are stable across locales and copy changes.
3. Put the flow in `apps/mobile/.maestro/<flow-name>.yaml` in the project (if this is the Prosper XO repo — adapt to other projects).
4. Add an `- assertVisible:` after every significant transition so the flow fails fast when UI changes.

### Skeleton

```yaml
appId: com.example.MyApp
---
- launchApp:
    clearState: true
- assertVisible:
    id: "home-screen"
- tapOn:
    id: "signup-button"
- assertVisible:
    id: "signup-screen"
- inputText: "user@example.com"
- tapOn:
    id: "continue-button"
- takeScreenshot: "after-signup"
```

### Running

```bash
maestro test apps/mobile/.maestro/signup-flow.yaml
maestro studio                  # Interactive flow authoring — records your taps
```

## When Maestro is the wrong tool

- Needs precise pixel-level control (design review: this skill)
- Needs to correlate with simctl-specific features like push payloads or location spoofing (this skill)
- Needs to read logs mid-flow (this skill — Maestro has limited log access)

## When Maestro beats this skill

- Runs in CI without a human
- Survives minor UI tweaks if you use `id` selectors
- Cross-platform (Maestro flows work on Android too, mostly)
- Faster iteration on **repeated** flows because you don't re-author each run

## Interop

You can call this skill's scripts **from within** a Maestro flow using `runScript`:

```yaml
- runScript:
    file: ../scripts/set_prosper_test_location.sh
- tapOn:
    id: "use-location-button"
```

That lets you combine Maestro's reliable UI interaction with this skill's simctl/idb state-manipulation capabilities.
