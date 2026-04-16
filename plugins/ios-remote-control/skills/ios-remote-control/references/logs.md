# Log predicates cookbook

Apple's unified logging uses NSPredicate syntax. Here are recipes for the environments this skill commonly touches.

## Basic structure

```bash
xcrun simctl spawn <UDID> log stream --style compact --level <default|info|debug> \
  --predicate '<NSPredicate>'
```

Predicate fields that matter:
- `subsystem` — matches a bundle identifier-style string your code calls `Logger(subsystem:)` with
- `process` — the process name (often the last segment of bundle id)
- `category` — free-form string within a subsystem
- `eventMessage` — the log text itself
- `senderImagePath` — framework path (catches system vs. app origin)
- `type` — `debug`, `info`, `default`, `error`, `fault`

Operators: `==`, `!=`, `CONTAINS`, `BEGINSWITH`, `ENDSWITH`, `MATCHES` (regex), `AND`, `OR`, `NOT`.

## Recipes

### One specific app (by bundle id)

```bash
--predicate 'subsystem == "com.example.MyApp"'
```

But many apps don't set `subsystem` at all — especially React Native apps using `console.log`. Fall back to process name:

```bash
--predicate 'process == "MyApp" OR subsystem == "com.example.MyApp"'
```

### React Native / Expo apps

RN's console output goes through the Metro bridge and ends up in the `ReactNativeJS` category. Expo adds its own process.

```bash
# All JS logs
--predicate 'category == "ReactNativeJS" OR process CONTAINS "Expo"'

# Errors and fatals only
--predicate '(category == "ReactNativeJS" OR process CONTAINS "Expo") AND type == error'
```

### Hermes engine errors

Hermes logs JS exceptions via `os_log` with category `Hermes`:

```bash
--predicate 'category == "Hermes" AND eventMessage CONTAINS "Error"'
```

### SwiftUI view lifecycle

```bash
--predicate 'subsystem == "com.apple.SwiftUI" AND category == "LifecycleLogger"'
```

### Network (NSURLSession)

```bash
--predicate 'subsystem == "com.apple.network" OR subsystem == "com.apple.CFNetwork"'
```

This is *loud* — filter by `eventMessage CONTAINS "my.api.domain.com"` to narrow.

### Exclude system noise

```bash
--predicate 'NOT (subsystem BEGINSWITH "com.apple") AND type >= info'
```

### Only crashes / faults

```bash
--predicate 'type == fault OR eventMessage CONTAINS "Fatal"'
```

## Tips

- Add `--level debug` when you need `os_log(.debug, ...)` messages. Default level hides them.
- `--info` and `--debug` flags are shortcuts: `--info` = `--level info`, `--debug` = `--level debug`.
- Use `log_tail.sh --save` to capture a bounded window to a file. Then grep through it. Live grep on stream is possible but the stream is high-volume and easy to miss.
- If nothing shows up, verify the app is actually emitting logs: `log stream --predicate 'process == "MyApp"'` with no other filter.

## Getting from "something is wrong" to the error

1. Reproduce the bad state (tap/navigate/etc. with this skill).
2. Right after, run `log_tail.sh --bundle com.example.MyApp --duration 10 --save`.
3. Read the returned `.log` file.
4. Grep for `error`, `fault`, `exception`, `fatal`, `nil`, `undefined`.
5. If nothing: broaden predicate to `process == "MyApp"` (no subsystem filter).
6. If still nothing: the app may be crashing silently. Check `crash_logs.sh`.

## Collecting a logarchive (for deeper post-mortem)

```bash
xcrun simctl spawn <UDID> log collect --output /tmp/sim.logarchive
open /tmp/sim.logarchive   # Opens in Console.app
```

Useful when you need to browse interactively or share with a teammate.
