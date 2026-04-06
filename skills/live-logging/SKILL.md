---
name: live-logging
description: >
  Live debugging with macOS unified logging for solstone-macos. Log streaming,
  category filtering, Logger extension patterns, privacy annotations, and log
  level guidance. Use when debugging the running app, adding log statements,
  or troubleshooting logging issues.
---

# Live Logging & Debugging

macOS unified logging (`os.Logger`) for solstone-macos. Subsystem and categories defined in `Log.swift`.

## 1. Logger Architecture

`Log.swift` — `Logger` extension with static properties per category. Call sites use `Logger.<category>.<level>(...)` directly, giving the compiler access to the string interpolation for optimized binary encoding, per-value privacy control, and accurate source location in Console.app.

Read `Log.swift` for the current subsystem, categories, and file-to-category mapping.

## 2. Live Streaming

**Always use `/usr/bin/log`** — fish shell has a `log` builtin that shadows it.

### Stream all solstone logs
```bash
/usr/bin/log stream --predicate 'subsystem == "app.solstone.capture"' --level debug
```

### Filter by category
```bash
/usr/bin/log stream --predicate 'subsystem == "app.solstone.capture" AND category == "audio"' --level debug
```

### Filter by message content
```bash
/usr/bin/log stream --predicate 'subsystem == "app.solstone.capture" AND eventMessage CONTAINS "[Heartbeat]"' --level debug
```

### Stream to file for automated capture
```bash
/usr/bin/log stream --predicate 'subsystem == "app.solstone.capture"' --level debug > /tmp/solstone_logs.txt 2>&1 &
# ... run the app, reproduce the issue ...
kill %1
cat /tmp/solstone_logs.txt
```

### Debug workflow: kill, stream, relaunch
```bash
pkill -f solstone
/usr/bin/log stream --predicate 'subsystem == "app.solstone.capture"' --level debug > /tmp/solstone_logs.txt 2>&1 &
STREAM_PID=$!
open /Applications/solstone.app   # or: .build/debug/solstone &
sleep 5 && cat /tmp/solstone_logs.txt
kill $STREAM_PID
```

**Prefer `log stream` over `log show`** — `log show` reads the on-disk log store, which can be corrupted by macOS logd bugs. `log stream` captures from the real-time tracing pipeline and always works.

## 3. Log Levels

| Level | Persistence | Use for |
|-------|------------|---------|
| `debug` | Never persisted; only visible in `log stream --level debug` | Verbose diagnostics. Zero overhead when not streaming. |
| `info` | In-memory only; captured retroactively on error/fault | Context for "what happened before the error" |
| `notice` | Always persisted to disk | Essential operational events |
| `warning` | Always persisted | Degraded but recoverable |
| `error` | Always persisted; triggers retroactive info capture | Recoverable process-level errors |
| `fault` | Always persisted + extra system state | Logic errors, impossible states. Use sparingly. |

## 4. Writing Log Statements

### Basic pattern
```swift
import os

Logger.capture.info("Started recording with \(displays.count, privacy: .public) display(s)")
Logger.audio.error("Stream failed: \(error, privacy: .public)")
```

### Privacy annotations (required on all interpolated values)
```swift
Logger.capture.info("Display \(displayID, privacy: .public)")          // always visible
Logger.setup.info("Server URL: \(url, privacy: .private)")             // redacted unless debugger attached
Logger.audio.info("Device \(deviceUID, privacy: .private(mask: .hash))") // consistent hash for correlation
```

### self. requirement in async/closure contexts

`Logger` methods take `@autoclosure () -> OSLogMessage`. In Swift 6, property references inside Logger interpolations need explicit `self.` when inside async methods or closures. Local variables don't need `self.`.

```swift
// Inside an async method or closure:
Logger.capture.info("Display \(self.displayID, privacy: .public)")  // property — needs self.
let count = items.count
Logger.capture.info("Processing \(count, privacy: .public) items")  // local — no self.
```

### Verbose-gated debug logging

Some components have a `verbose` property. Gate debug calls to suppress even from live streaming:

```swift
if verbose { Logger.audio.debug("Buffer received: \(format, privacy: .public)") }
```

### Contextual tags

Log messages use bracket tags for grep-friendly filtering. Grep the source for `\[Tag\]` patterns in Logger calls to find the current set.
