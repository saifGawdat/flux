# Flux — Implementation Roadmap

Status legend: ✅ done and tested · 🟡 foundation only (see notes) · ⬜ not started

## Environment constraints (current dev machine)

- Command Line Tools only (no Xcode): the app is built with Swift Package Manager and
  wrapped into `Flux.app` by `scripts/build-app.sh`.
- XCTest ships with Xcode, not the CLT. Tests use **Swift Testing** (`import Testing`),
  which is available here and also runs inside Xcode. If XCTest is a hard requirement,
  install Xcode and the suites can be ported mechanically.

## Phase 1 — Foundation ✅

- SwiftPM workspace: `FluxCore` (library, all business logic), `Flux` (SwiftUI app).
- Swift 6 language mode with strict concurrency.
- Core models: `DownloadRecord`, `Segment`, `DownloadStatus`, `DownloadPriority`, `FluxSettings`.
- SQLite persistence (system `libsqlite3`, thin wrapper) with versioned migrations.
- Download engine (`DownloadJob` actor): multi-connection Range downloads, single-stream
  fallback, pause/resume (also across restarts), retry with exponential backoff,
  adaptive connection limit, If-Range change detection, coverage + size validation
  before the final file is placed, quarantine + "Where from" metadata.
- `DownloadManager` actor: queue with max concurrent downloads and priority ordering,
  persistence, crash/quit recovery, event stream for UIs (and later IPC).
- Downloads UI: sidebar filters, per-connection segment progress bars, add sheet,
  context menus, drag & drop of links, settings.
- Graceful quit: active downloads are checkpointed before the app exits.

## Universal media, playlists & images (inserted after Phase 1) ✅

- `TransferJob` protocol: the manager drives file and media engines identically.
- `MediaJob`: runs yt-dlp (1,800+ sites) in a private work folder; progress, pause/resume,
  cancel, friendly errors, never-overwrite placement, quarantine.
- Routing: known media sites → yt-dlp; file links answering with an HTML page → yt-dlp.
- Format presets; graceful behavior without ffmpeg; tool status in Settings.
- Playlists ✅: YouTube playlists/channels (and other yt-dlp lists) open as a checklist;
  each video becomes its own download in a group, one format for all, own folder.
- Quality presets ✅: Best, 4K, 1440p, 1080p, 720p, 480p MP4, MP3, M4A.
- Images ✅: gallery-dl galleries (Instagram, Reddit, Flickr, …) and a built-in page scan
  for every other site; picked from a thumbnail grid, downloaded by Flux's own engine
  with the page as Referer.
- Polish ✅: grouped list with overall progress and group actions, Retry Failed, search by
  title/playlist, drop a page link → add sheet, connections hidden for media.
- Not yet: managed tool install/updates inside Flux, cookies/sign-in from inside Flux,
  subtitle download, numbering files by playlist position.

## Phase 2 — Download engine ⬜
Per-download/global bandwidth limits (token bucket shared across jobs), SHA-256
verification against user-supplied checksums, mirrors, expired-URL refresh flow,
explicit Content-Length validation surfaced in UI, priority editing in UI.

## Phase 3 — Smart management ⬜
Category folders, rule engine (extension / pattern / domain / size / category),
duplicate detection (size + hash), archive extraction, history view.

## Phase 4 — Power user ⬜
TXT/CSV/JSON import & export, multiple named queues with schedules, clipboard
monitoring (opt-in, always asks), `flux` CLI talking to the app over a protected
Unix domain socket in the user's Application Support folder (0600 permissions,
peer UID check), sharing the app's `DownloadManager`.

## Phase 5 — macOS integration ⬜
Menu bar extra, notifications, dock progress, Quick Look, Spotlight (Core Spotlight
index of history), launch at login (`SMAppService`), global shortcuts.

## Phase 6 — Analytics & automation ⬜
Bandwidth samples table + Swift Charts dashboard, per-domain stats, post-download
action pipeline (move/rename/extract/verify/notify/reveal/approved commands).

## Phase 7 — Production ⬜
Security audit, Developer ID signing, notarization, DMG, Sparkle updates.

## Out of scope (future, architecture keeps room)
AI assistant and browser extensions. Both would talk to `DownloadManager` through
the same IPC surface the CLI uses — nothing in the core depends on them.
