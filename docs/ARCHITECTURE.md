# Flux — Architecture

```
Flux (SwiftUI app, @MainActor)            FluxCore (library, no UI)
┌──────────────────────────┐   intents    ┌───────────────────────────────┐
│ AppModel (@Observable)   │ ───────────▶ │ DownloadManager (actor)        │
│  ├─ DownloadItemModel    │              │  ├─ queue / priority / limits  │
│  └─ views (Features/*)   │ ◀─────────── │  ├─ recovery after restart     │
└──────────────────────────┘ AsyncStream  │  ├─ FluxDatabase (actor,SQLite)│
                              <Event>     │  └─ DownloadJob (actor) × N    │
                                          │       └─ URLSession + pwrite   │
                                          └───────────────────────────────┘
```

Future clients (CLI, browser extensions) attach to `DownloadManager` through an IPC
layer that forwards the same intents and subscribes to the same event stream. There is
exactly one engine.

## Decisions

### D1 — One actor per download, executing on its URLSession delegate queue
`DownloadJob` is an `actor` whose custom executor is a `DispatchSerialQueue`. The
URLSession's delegate `OperationQueue` uses that same queue as its `underlyingQueue`,
so delegate callbacks are already on the actor's executor and enter it synchronously
with `assumeIsolated`. Benefits: compiler-checked isolation (no `@unchecked Sendable`,
no locks), and byte chunks are processed strictly in arrival order with no extra hops.

### D2 — Segments write into one sparse part file
Each connection `pwrite`s at its own offset in a preallocated `<name>.<id>.fluxpart`
file in the destination folder (same volume → final `rename` is atomic). There is no
separate "merge" step that could corrupt data; instead, before the file is moved into
place, `finalize` checks that:
1. every segment is complete,
2. the segments cover `[0, total)` exactly, with no gaps or overlaps,
3. the on-disk size equals the expected total (Content-Range / Content-Length).
If any check fails the download restarts from scratch instead of producing a bad file.

### D3 — Dynamic segmentation
The first request is `Range: bytes=0-`. A `206` with a total size proves range support
and keeps streaming as segment 0. Additional connections are created by halving the
segment with the most bytes left. When a connection finishes, it steals half of the
largest remaining segment, so no connection idles near the end. A server that rejects
extra connections lowers the job's connection limit instead of failing the download.

### D4 — Change detection on resume
Resumed ranges carry `If-Range` (strong ETag, else Last-Modified). If the file changed,
the server answers `200` with the full body; the job detects this (also a mismatched
Content-Range total) and restarts rather than stitching two versions together.

### D5 — Checkpointing and crash safety
The job `fsync`s the part file before emitting a *checkpoint* snapshot (every 2 s);
only checkpoints and status changes are written to SQLite. A persisted byte count is
therefore never ahead of durable data. On force-quit or crash at most the last ~2 s
are re-downloaded. On normal quit, `applicationShouldTerminate` waits for
`DownloadManager.shutdown()` to checkpoint every active job.

Lifecycle behavior (verified by tests where possible):
| Event | Behavior |
|---|---|
| Close window | App keeps running, downloads continue (reopen from Dock). |
| Quit (⌘Q) | Active downloads are checkpointed; resumed on next launch if “Resume on launch” is on. |
| Force quit / crash | Downloads stop. On next launch they resume from the last checkpoint. |

### D6 — SQLite via system libsqlite3, not GRDB
Phase 1 needs a handful of queries and versioned migrations. A ~150-line wrapper over
the system library avoids a third-party dependency and network fetch while keeping
full control over Sendable correctness (the connection is owned by the `FluxDatabase`
actor). If query complexity grows (history search, analytics), switching to GRDB is
contained to `Persistence/`.

Migrations are ordered SQL scripts keyed by `PRAGMA user_version`, each applied in a
transaction. Opening a database created by a *newer* Flux fails loudly instead of
corrupting it.

### D7 — Security baseline
- TLS validation is never disabled. The app's `Info.plist` allows plain-HTTP loads
  because a download manager must fetch `http://` URLs; this does not affect HTTPS
  certificate checks.
- Server-provided file names are sanitized (no `/`, `:`, control characters, leading
  dots, length-capped) and resolved within the chosen folder; existing files are never
  overwritten (`name (1).ext`).
- Finished files get the `com.apple.quarantine` attribute so Gatekeeper checks
  downloaded apps, plus `kMDItemWhereFroms` for Finder's "Where from".
- Only `http`/`https` URLs are accepted.
