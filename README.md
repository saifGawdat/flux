# Flux

**Everything you download. Under control.**

A native macOS download manager for Apple Silicon, built with Swift 6, SwiftUI and AppKit.

## Status

Phase 1 (foundation) is complete. See [docs/ROADMAP.md](docs/ROADMAP.md) for what exists
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
- Downloads window with per-connection progress bars, filters, search, drag & drop of
  links, context menus, settings

## Requirements

- macOS 14 or later on Apple Silicon
- Swift 6 toolchain (Xcode or the Command Line Tools)

## Build and run

```sh
./scripts/build-app.sh      # → build/Flux.app (arm64, ad-hoc signed)
open build/Flux.app
```

For development, `swift run Flux` also launches the app (without a bundle identifier).

## Tests

```sh
./scripts/test.sh
```

Uses Swift Testing. Engine tests run against `scripts/range_server.py`, a local HTTP
server with Range/If-Range support, throttling and redirect/Content-Disposition modes —
no public URLs are contacted.

## Data

- Database: `~/Library/Application Support/Flux/flux.sqlite`
- Logs: `log stream --predicate 'subsystem == "app.flux"'`
- Partial downloads: `<name>.<id>.fluxpart` next to the destination file
