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

## Phase 2 — Download engine ✅

- Bandwidth limits ✅: global (shared token bucket) and per download, changeable while
  running. Ranged downloads pace their requests (half a second of data per request);
  servers without ranges are paused per connection; yt-dlp is held with SIGSTOP/SIGCONT.
  Under a limit Flux opens one connection per 1 MB/s of allowed speed.
- Checksums ✅: SHA-256, SHA-1, SHA-512, MD5 (recognized by length; pasted `shasum` lines
  work). Verified off the job's actor before the part file becomes the final file; a
  mismatch discards the data so Retry starts clean. Finished files can be checked later,
  and their SHA-256 calculated.
- Mirrors ✅: connections spread across all links; a mirror with another size, range
  errors or permanent HTTP errors is dropped; a dead main link fails over to mirrors.
- Expired-URL refresh ✅: Update Link… on any unfinished download; the new link is probed
  (size, ranges, page vs file) and the download continues from where it stopped.
- Size validation surfaced ✅: `sizeVerified` per download, seal in the list, size check in
  the Info window; "size unknown" while downloading streams without a stated size.
- Priority editing ✅: context menu, group header and Info window.
- Fixed along the way: servers with unquoted ETags or that ignore If-Range (e.g. Wikimedia's
  CDN) no longer restart multi-connection downloads from scratch.
- Not yet: per-host connection limits, scheduled speed limits (Phase 4 schedules).

## Phase 3 — Smart management ✅

- Categories ✅: Documents, Images, Videos, Music, Archives, Apps, Other (by extension;
  media by format). Optional folders by kind; sidebar "Kinds" filter with counts.
- Rule engine ✅: conditions extension (incl. `tar.gz`), name glob, site (with subdomains and
  the page a link came from), link contains, larger/smaller than, kind; all must match;
  ordered, first match wins; enable/disable, reorder, edit in Settings › Organize. Applied
  when a download finishes, so names from Content-Disposition count. Only downloads saved
  to Flux's default folder are moved (`autoFile`).
- Duplicate detection ✅: same size, then SHA-256, against earlier downloads and files in
  the same folder; keep both (marked) or trash the new copy. Same-link warning in the add sheet.
- Archive extraction ✅: system bsdtar (zip, tar.*, 7z, rar), private work folder, single
  top-level item placed as is, else a folder named after the archive; unsafe symlinks
  removed; quarantine propagated; optional trash of the archive; Extract / Try Again.
- History ✅: Clear Completed archives instead of deleting; History view grouped by day,
  search, Download Again, Remove, Clear History.
- Not yet: watching folders for files added outside Flux, renaming rules, per-rule
  actions beyond the folder.

## Phase 4 — Power user ✅

- Named queues ✅: sidebar › Queues (Main plus your own), Start/Stop by hand, per-queue
  downloads-at-a-time, move downloads between queues (right-click › Queue), queue choice in
  the add and import sheets. Stopping a queue pauses its running downloads back to waiting.
- Schedules ✅: days of the week, start time, optional stop time (overnight windows work).
  Checked every 10 s; launching inside a window starts the queue; without a stop time the
  queue stops itself once nothing in it is waiting.
- Import ✅: .txt (links anywhere in a line, `#` comments, aria2 `out=`/`dir=`/`checksum=`/
  `referer=` option lines, tab-separated mirrors), .csv (header names like url/link, name,
  folder, checksum, mirrors; `,` `;` or tab; quoted fields; or no header), .json (Flux's
  export, an array of links or objects). Content beats extension; 20 MB / 10,000 links max.
- Export ✅: text, CSV (spreadsheet-safe: formula-looking cells are quoted) and JSON with
  status, size, checksum/SHA-256, dates; optionally including History.
- Clipboard ✅ (opt-in): links to files (by extension) and video pages only; concealed /
  transient pasteboard types (password managers) and Flux's own copies are skipped; each link
  is offered once; floating panel with Download / Options… that hides after 15 s.
- `flux` CLI ✅: add (folder, name, queue, paused, `--wait`, stdin), import, export, list,
  status, pause/resume/cancel/remove (ID prefixes or `all`), limit, queues, queue start/stop,
  ping, `--json`. Opens Flux when it isn't running. Bundled at `Contents/Helpers/flux`;
  Settings › General links it into `/opt/homebrew/bin` or `/usr/local/bin`.
- Control socket ✅: Unix domain socket in Application Support, 0600, `getpeereid` UID check
  on every connection, newline-delimited JSON with a protocol version, 4 MB message cap, stale
  sockets replaced, a live one never taken over.
- Not yet: scheduled speed limits, "when the queue finishes" actions (sleep/quit),
  per-queue speed limits.

## Phase 5 — macOS integration ✅

- Menu bar ✅: `MenuBarExtra` window with running/waiting/paused downloads (progress, speed,
  time left), the three most recent finished or failed, Add Download, Pause/Resume All, speed
  limit, Open Flux, Settings, Quit. Icon fills while downloading. Can be hidden.
- Notifications ✅: finished and failed (each switchable); downloads finishing within 1.5 s
  are one notification; a playlist/gallery is one notification when its last download
  stops; cancellations and what was already finished at launch say nothing. Actions: Open,
  Show in Finder, Try Again; clicking selects the downloads in Flux. Banners only while Flux
  is in the background. Permission is asked at the first notification.
- Dock ✅: progress bar over the icon (bytes of running downloads with a known size, redrawn per
  whole percent, at most twice a second), the count badge, and a Dock menu (Add Download,
  Pause/Resume All, speed limit). Clicking the Dock icon reopens a closed window.
- Quick Look ✅: Space in the list and History, File › Quick Look (⌘Y), right-click › Quick
  Look; pages through all selected finished files (extracted folders too).
- Spotlight ✅: Core Spotlight items for finished downloads whose file exists (title, file,
  site, playlist, link, date; never expire), rebuilt at launch (newest 10,000), then only
  changes sent (finished, moved by a rule, trashed, removed). A result opens Flux with the
  download selected (History if cleared). Switchable; off removes the items.
- Open at login ✅: `SMAppService.mainApp`, with the "switched off in Login Items" state shown.
- Global shortcuts ✅: Carbon hot keys (no Accessibility permission, sees only its own keys):
  Add download from copied link (⌃⌥⌘D by default), Show/Hide Flux, Pause/Resume All.
  Recorder in Settings › System; only combinations with two of ⌃⌥⌘ (or function keys)
  are accepted; one action per combination; taken combinations are flagged.
- Not yet: hiding the window when opened at login, a progress ring in the menu bar icon,
  key names for non-US keyboard layouts in the shortcut recorder.

## Phase 6 — Analytics & automation ✅

- Traffic ✅: `traffic` table (schema v8) of bytes per minute and site (the page a download came
  from, else its host, without `www.`), counted from progress deltas while Flux runs, written
  every 10 s and at quit, kept 90 days.
- Statistics ✅: sidebar › Statistics with Swift Charts: 24 hours (per hour), 7 or 30 days (per
  day), downloaded, finished, failed with success rate, fastest minute, top sites (received,
  finished, failed), finished by kind. Refreshes every 10 s. `flux stats [day|week|month]`
  (with `--json`).
- Action pipeline ✅: the first matching rule now decides actions as well as the folder, in a
  fixed order: rename → move (default-folder downloads only; "Move it to" can be off) →
  duplicate check → extract → SHA-256 → command → notify / show in Finder / open. Actions also
  apply to downloads saved to a folder the user picked. Results and problems are kept per
  download (`automation_note`) and shown in the list and the Info window.
- Rename patterns ✅: `{name}` `{title}` `{site}` `{date}` `{year}` `{month}` `{day}` `{time}`
  `{kind}` `{playlist}` `{index}` `{id}`; the extension is kept; never overwrites.
- Approved commands ✅: Settings › Automation; zsh with the file as `$1` and `FLUX_*` variables,
  no profile, the file's folder as working directory, a fixed PATH, 5-minute limit, output
  kept to the last line. Saving asks for approval of the exact text (SHA-256); a changed text
  doesn't run until approved again. "Test on a File…" runs it once.
- Not yet: user-ordered action steps, per-site speed history charts, CSV export of statistics,
  verifying against a checksum file as an action.

## Phase 7 — Production ⬜
Security audit, Developer ID signing, notarization, DMG, Sparkle updates.

## Out of scope (future, architecture keeps room)
AI assistant and browser extensions. Both would talk to `DownloadManager` through
the same IPC surface the CLI uses — nothing in the core depends on them.
