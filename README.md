# Flux

**Everything you download. Under control.**

A native macOS download manager for Apple Silicon, built with Swift 6, SwiftUI and AppKit.

## Status

Phases 1 (foundation), 2 (download engine), 3 (smart management), 4 (power user), 5 (macOS
integration) and 6 (analytics & automation) are complete. See [docs/ROADMAP.md](docs/ROADMAP.md) for what exists
and what is next, and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for design decisions.

What works today:
- Multi-connection downloads using HTTP Range, with automatic single-connection fallback
- Dynamic splitting: finished connections take over half of the largest remaining piece
- Pause / resume, including after quitting or a crash (SQLite-persisted checkpoints)
- Change detection on resume (If-Range): no stitching of two different file versions
- Validation before the final file is placed: full coverage, no gaps, exact size
- Retry with exponential backoff; automatic connection reduction for strict servers
- Queue with simultaneous-download limit and High / Normal / Low priority
- Safe file names (sanitized, never overwrite: `name (1).ext`), quarantine + “Where from”
- **Video & audio from 1,800+ sites** (YouTube, Vimeo, X, TikTok, Instagram, SoundCloud, …)
  via yt-dlp: best quality, 1080p/720p MP4, MP3 or M4A; pause/resume; links that turn out
  to be web pages are handed to yt-dlp automatically
- **Playlists and channels at once**: paste a playlist (or a video opened from one) and
  tick the videos you want; one format and quality for all (Best, 4K, 1440p, 1080p, 720p,
  480p MP4, MP3, M4A), saved into a folder named after the playlist
- **Images**: galleries from Instagram, Reddit, Flickr, Tumblr and 100+ sites via
  gallery-dl, and the pictures on any other web page via Flux's own page scan; pick them
  from a thumbnail grid
- Playlists and image sets show as one collapsible group with overall progress and
  group actions (pause, resume, retry, show in Finder)
- Thumbnails in the list: the video's thumbnail while it downloads (instantly for YouTube),
  and a QuickLook preview of the real file (image, video frame, PDF page) once it's done
- **Speed limits**: one for all downloads together (Settings, the speed in the status bar,
  or ⌥⌘L) and one per download (right-click › Speed Limit); both apply while running,
  videos included
- **Checksums**: paste a SHA-256 / SHA-1 / SHA-512 / MD5 when adding a file; Flux checks it
  before saving and discards a file that doesn't match. Finished files can be checked later
- **Mirrors**: paste several links to one file and tick "These links are mirrors": Flux
  spreads connections across them, ignores a mirror with a different file, and carries on
  when one link dies
- **Expired links**: a failed download can continue from a fresh link (Update Link…); Flux
  checks the new link serves the same file and keeps the data already downloaded
- Size check surfaced: finished files show whether they match the size the server stated
- Info window (⌘I) per download: link, mirrors, checksum, size check, priority, speed limit
- **Folders by kind** (opt-in): finished files go to Documents, Images, Videos, Music,
  Archives or Apps inside the download folder; the sidebar filters by kind too
- **Rules** (Settings › Organize): extension, name pattern, site, link text, size or kind →
  folder; first match wins; folders you pick yourself are never changed
- **Duplicates**: a finished file identical (size, then SHA-256) to one you already have is
  marked, or its new copy moved to the Trash
- **Archives** (opt-in): zip, tar.gz/bz2/xz, 7z and rar extracted next to the archive,
  quarantined, never overwriting; entries that climb out of the folder are refused
- **History**: Clear Completed (⇧⌘K) moves finished downloads to History, grouped by day,
  with search, Download Again and Clear History
- **Queues**: named queues (sidebar › Queues) hold downloads until you start them, or start
  and stop on a schedule (days, start time, optional stop time), with their own
  downloads-at-a-time limit
- **Import / export**: File › Import Links… (⌘O) reads .txt (one link per line, aria2
  `out=`/`dir=`/`checksum=` lines), .csv (with or without a header) and .json; File › Export
  Downloads writes the same formats
- **Clipboard** (opt-in, Settings › General): copy a link to a file or video and Flux asks,
  in a small panel, whether to download it
- **`flux` command line**: `flux add <link> --wait`, `flux list`, `flux pause all`,
  `flux limit 2M`, `flux queue start Night`, `flux import links.txt`, … (Settings › General ›
  Install, or `build/Flux.app/Contents/Helpers/flux`)
- **Menu bar**: running downloads with progress, recent ones, Add Download, Pause All and the
  speed limit, also with the window closed (Settings › System to hide it)
- **Notifications** when downloads finish (several at once, or a whole playlist, come as one)
  or fail, with Open / Show in Finder / Try Again; Dock icon progress bar and Dock menu
- **Quick Look**: Space or ⌘Y previews finished files in the list and History
- **Spotlight**: finished downloads are found by name, site or playlist; a result opens the
  download in Flux
- **Open at login** and **global shortcuts** (⌃⌥⌘D adds a download from the copied link from
  any app; Show/Hide Flux and Pause/Resume All can be assigned), Settings › System
- **Statistics** (sidebar): downloaded per hour or day for 24 hours / 7 / 30 days, finished
  and failed, fastest minute, top sites, finished by kind; also `flux stats`
- **Rule actions** (Settings › Organize): besides moving, a rule can rename (`{date} {name}`,
  `{site}`, `{playlist}`, …), extract, calculate SHA-256, run a command, notify, show in
  Finder or open
- **Commands** (Settings › Automation): zsh scripts rules run with the file as `$1`; each runs
  only exactly as you approved it, for at most 5 minutes
- Downloads window with per-connection progress bars, filters, search, drag & drop of
  links, context menus, settings

## Requirements

- macOS 14 or later on Apple Silicon
- Swift 6 toolchain (Xcode or the Command Line Tools)

## Video and gallery downloads (optional tools)

Flux downloads direct file links and the images on ordinary pages by itself. For
video/audio pages and image galleries it uses free command-line tools — install them once:

```sh
brew install yt-dlp ffmpeg gallery-dl
```

Flux finds them automatically (Settings → Video, Audio & Images shows their status).
gallery-dl reads its own config (`~/.config/gallery-dl/config.json`), so sites that need
a login work once you've added cookies there. Without
ffmpeg, Flux still downloads video, but only formats that come as a single file
(usually up to 720p on YouTube) and can't convert to MP3.

Only download media you have the right to save; some sites' terms forbid it.

## Build and run

```sh
./scripts/build-app.sh      # → build/Flux.app (arm64, ad-hoc signed)
open build/Flux.app
```

For development, `swift run Flux` also launches the app (without a bundle identifier).

## Command line

`flux` sends each command to the running app (it opens Flux if needed), so Terminal and the
window always show the same downloads. Run `flux help` for everything; `--json` on any
command gives machine-readable output, and `flux add … --wait` exits 0 only when every
download succeeded.

```sh
flux add https://example.com/big.iso -o ~/ISOs --wait
cat links.txt | flux add - -q Night
flux list
flux pause all && flux limit 500K
flux stats month
```

## Tests

```sh
./scripts/test.sh
```

Live checks against real sites (opt-in, needs network and the tools above):

```sh
FLUX_LIVE_TESTS=1 ./scripts/test.sh --filter "LiveMediaTests|LiveCollectionTests"
```

Uses Swift Testing. Engine tests run against `scripts/range_server.py`, a local HTTP
server with Range/If-Range support, throttling, redirect/Content-Disposition, expiring
link, no-length and picky-CDN modes — no public URLs are contacted.

## Design

Theme, palette and logo direction: [docs/BRAND.md](docs/BRAND.md). To preview the
themed list without a screen recording permission:

```sh
FLUX_SNAPSHOT=/tmp/flux.png build/Flux.app/Contents/MacOS/Flux          # light
FLUX_SNAPSHOT=/tmp/flux-dark.png FLUX_SNAPSHOT_DARK=1 build/Flux.app/Contents/MacOS/Flux
# the add sheet for a link, after it has been inspected (drawn off-screen):
FLUX_SNAPSHOT=/tmp/add.png FLUX_SNAPSHOT_ADD="https://…" build/Flux.app/Contents/MacOS/Flux
# the Info window of the n-th download (FLUX_SNAPSHOT_EDITLINK=1 opens Change Link):
FLUX_SNAPSHOT=/tmp/info.png FLUX_SNAPSHOT_INFO=0 build/Flux.app/Contents/MacOS/Flux
# Settings › Organize (organize), General (general), System (system), Automation
# (automation), the first rule's editor (rule), Statistics (statistics), the menu bar window
# (menubar), History (history), the first queue's
# editor (queue) or list (queues), the clipboard prompt (clipboard), or the import sheet for
# FLUX_SNAPSHOT_FILE (import):
FLUX_SNAPSHOT=/tmp/org.png FLUX_SNAPSHOT_VIEW=organize build/Flux.app/Contents/MacOS/Flux
```

## Data

- Database: `~/Library/Application Support/Flux/flux.sqlite`
- Command socket: `~/Library/Application Support/Flux/control.sock` (owner-only; override
  with `FLUX_SOCKET`, which a `FLUX_DATABASE` developer instance needs to accept commands)
- Traffic: bytes per minute and site in the `traffic` table of the database, kept 90 days
- Spotlight: finished downloads are listed under the domain `app.flux.downloads` (turn off in
  Settings › System to remove them)
- Logs: `log stream --predicate 'subsystem == "app.flux"'`
- Partial downloads: `<name>.<id>.fluxpart` next to the destination file
