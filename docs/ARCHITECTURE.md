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

### D8 — Media pages go through yt-dlp, not a home-grown extractor
Sites like YouTube serve video through signed, expiring, frequently changing stream URLs,
often as separate video and audio streams. Keeping extractors current for hundreds of
sites is a full-time project, so Flux delegates to yt-dlp (+ ffmpeg for merging and
conversion) as an external, user-installed tool:
- yt-dlp runs with its working folder set to `.flux-<id>` inside the destination, so
  pause (SIGINT keeps `.part` files), resume (`--continue`) and cancel (delete folder)
  are isolated per download. Flux moves the finished file into place itself.
- Flux asks for machine-readable output (`--progress-template`, `--print`) instead of
  scraping the human progress bar. The URL is passed after `--` so it can't be read as
  an option.
- Links are routed by host; any "file" link that answers with `text/html` is retried
  through yt-dlp, so pages from unknown sites work too.

### D9 — Playlists and galleries become groups of ordinary downloads
A playlist or gallery is not a new kind of job. The add sheet asks `LinkInspector` what
a link holds — yt-dlp (`-J --flat-playlist`, one fast request), gallery-dl (`-j`, metadata
only) and, for sites gallery-dl doesn't know, `PageImageScanner` reading the HTML — and
turns the user's picks into normal downloads that share a `DownloadGroup` (id, title,
kind) and a `groupIndex`:
- Videos are media downloads (one yt-dlp run each, `--no-playlist`), so pause, resume,
  retry, priority and the concurrency limit work per video with no new code paths.
- Images are file downloads through Flux's own engine, carrying the page as `Referer`
  (some image hosts refuse requests without it). `ytdl:` links from gallery-dl become media
  downloads.
- One batch shares one `createdAt`; `DownloadRecord.listOrder`/`queueOrder` break ties by
  `groupIndex`, so a playlist is listed and downloaded in playlist order.
- The list draws a header for each run of consecutive group members (big groups start
  collapsed). Group actions are just the existing intents applied to the members' ids.

### D10 — Speed limits pace requests instead of pausing sockets
One `SpeedLimiter` (token bucket, lock-protected, may go into debt) is shared by every job
for the global limit; each job has its own for a per-download limit. Bytes are charged
after they arrive and the slowest bucket decides the wait.

Pausing a `URLSessionDataTask` does **not** stop CFNetwork from reading the socket: it keeps
buffering in memory and delivers everything on resume (measured: 7 MB in one burst at a
"1 MB/s" limit). So under a limit, ranged downloads ask for ~0.5 s of data per request
(`Range: bytes=a-b`) and only send the next request when the bucket is out of debt; a
server can't send more than was asked. Keep-alive makes the extra requests cheap. Servers
without ranges fall back to suspending the task (best effort). yt-dlp downloads are
charged from their progress lines and held with SIGSTOP/SIGCONT (yt-dlp and its children),
which does stop socket reads. Overshoot is at most one chunk per connection.

### D11 — Mirrors, validators and verification
- `DownloadRecord.sources` = main link + mirrors. The probe uses the first usable link;
  segment connections go to the usable link with the fewest connections. The link whose
  first response defined the file is the reference: a different size from another link
  drops that link (never the download); from the reference it means the file changed.
- If-Range is sent only to the main link, and only with a strong, quoted ETag (else
  Last-Modified). A full 200 reply to an If-Range request whose size and validators still
  match means the server ignores If-Range: Flux stops sending it instead of restarting.
- A checksum is verified on the finished part file, off the actor, before the rename, so a
  bad file never appears under its real name. `sizeVerified` records that the server
  stated the size up front (finalize already refuses any other size).
- Editing link, mirrors or checksum of a running download pauses it, rebuilds its job from
  the edited record and resumes; new-link validators are cleared and the size check guards
  the kept data.

### D12 — Organizing happens after a download finishes
Filing, duplicate checks and extraction run in `DownloadManager.finishUp` once a job reports
`completed`, in that order, never inside the engine:
- The real file name is only certain at the end (Content-Disposition, yt-dlp titles), and
  the part file must stay on the volume where it was preallocated. Moving afterwards with
  `renamex_np(RENAME_EXCL)` (copy + remove across volumes) keeps the never-overwrite rule.
- Only downloads whose folder was Flux's default (`autoFile`) are moved; a folder the user
  picked, including a playlist's folder, is final.
- None of these steps can turn a finished download into a failure: problems are recorded
  (`extractionError`) and shown, with a retry.
- Extraction uses the system `bsdtar` (`--no-mac-metadata`, `__MACOSX` excluded) into a
  private `.flux-extract-*` folder; bsdtar refuses `..`/absolute entries and writing through
  symlinks by default, and symlinks pointing outside the folder are deleted before anything
  is moved into place. Extracted files get the same quarantine as the archive.
- `finishing` is marked synchronously in `apply` before any `await`, so no observer sees a
  finished download that hasn't started its post-processing.
- History is the same table: `archived` rows are hidden from the list, not deleted.
