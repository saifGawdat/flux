# Flux — Security Review (Phase 7)

Scope: everything in this repository as of Phase 6 (app, FluxCore, `flux` CLI, build
scripts). Threat model:

- **Untrusted input**: web servers and pages, link lists the user imports, archives, file
  names, media sites (through yt-dlp / gallery-dl), the clipboard.
- **Other user accounts** on the same Mac.
- **Out of scope**: malware already running as the user. It can do whatever Flux can.

## Findings fixed in this phase

| # | Severity | Finding | Fix |
|---|----------|---------|-----|
| 1 | High | An imported link list (`dir=` lines, CSV folder column, JSON `directory`) could choose any folder. A list from the web could save `x.plist` into `~/Library/LaunchAgents`, which macOS would run at the next login. | Imported folders are used only if they're inside the home folder (not `~/Library`) or on an external volume, contain no hidden component, and still qualify after resolving symlinks (`LinkList.isSafeFolder`). Otherwise the download goes to the default folder. The import sheet says so. Tests cover LaunchAgents, `~/.ssh`, `..` tricks, `/Applications`, `/tmp` and a symlink into Library. |
| 2 | Medium | The app wasn't signed with the hardened runtime (required for notarization; limits code injection). | `build-app.sh` signs the helper and the app with `--options runtime`, and with a secure timestamp when given a Developer ID. No entitlements are needed. The hardened build passed a full live run: downloads, rules, zsh commands, stats. |
| 3 | Low | The control socket served unlimited parallel connections. A same-user client could tie up threads. | At most 16 at once; extra connections are closed at once. Covered by a test. |
| 4 | Low | The database (download history, links, settings) was created with default permissions (folder 0755, files 0644). `~/Library` being 0700 protected it in practice. | Folder 0700, database files 0600, including `-wal`/`-shm`. Covered by a test. |
| 5 | Low | A file path was logged at public level when setting quarantine failed. | Logged as private. |

## Reviewed, no change needed

- **Control socket**:
  - The socket file is 0600, and every connection's `getpeereid` UID must match the app's own, which also covers the moment between `bind` and `chmod`.
  - Messages are capped at 4 MB with an idle timeout.
  - A live socket is never taken over, and a non-socket file at the path is never deleted.
  - The CLI can't create commands or change rules.
- **External tools** (yt-dlp, gallery-dl, ffmpeg, bsdtar):
  - They are started with argument arrays, never a shell.
  - URLs come after `--` and must be http(s), so a link can't become an option.
  - User file names in yt-dlp's `-o` have `%` escaped.
- **Automation commands**:
  - A command runs only while the SHA-256 of its text matches the digest stored when the user approved it.
  - The file is passed as `$1`, never spliced into the script; a test uses a file named `$(touch pwned)`.
  - Commands run with `zsh -f`, a fixed PATH, `FLUX_*` variables, and a 5-minute limit.
  - Imports and the CLI have no way to create commands.
- **File names and placement**:
  - Names from servers, Content-Disposition, media titles, `out=` and rename patterns all go through `FileNaming.sanitize`, so `/` and `:` are replaced and leading dots dropped.
  - Files are placed with `renamex_np(RENAME_EXCL)` and never overwrite.
  - Partial data is checked for full coverage and exact size before it becomes the file.
- **Quarantine**: downloaded files, media output and every extracted item get `com.apple.quarantine` plus "Where from". Renames and moves keep it.
- **Archives**:
  - Extraction uses `/usr/bin/tar` (bsdtar) with its secure defaults: no absolute paths, no `..`, and no writing through symlinks.
  - It extracts into a private work folder; symlinks pointing outside are removed and nothing is overwritten.
  - Extraction is opt-in, either in Settings or as a rule action.
- **TLS**: there is no custom trust handling, so the system validates certificates. `NSAllowsArbitraryLoads` exists only so plain `http://` links can be downloaded; HTTPS validation is unchanged.
- **SQL**: every statement takes parameters. The only interpolation is the integer in `PRAGMA user_version`.
- **Clipboard**:
  - It is opt-in and only offers links, never downloading without a click.
  - Concealed and transient pasteboard types (password managers) are never read.
  - Flux's own copies are skipped.
- **Global shortcuts**: Carbon `RegisterEventHotKey`, so there's no event tap, Flux sees only its own combinations, and no Accessibility permission is needed.
- **Spotlight**: items are local, in Flux's own domain, removed when turned off, and rebuilt at launch so deleted files drop out.
- **Imports**: files are capped at 20 MB and 10,000 links, and spreadsheet-formula cells are escaped on CSV export.

## Accepted risks and recommendations

1. **Archive bombs**: extraction has no output size cap, so a crafted archive can fill the disk. It is opt-in. Recommendation: check free space against the archive's listed size before extracting.
2. **Media tools are the user's own installs** (Homebrew) and read the user's yt-dlp and gallery-dl config files. Flux trusts them like any program the user installed. Recommendation: a managed install with pinned checksums (see ROADMAP "Not yet").
3. **Developer environment variables** (`FLUX_DATABASE`, `FLUX_SOCKET`, `FLUX_SNAPSHOT*`) work in release builds. Only whoever launches Flux can set them, so they give nothing beyond that user's own rights. They could be compiled out with `#if DEBUG` if wanted.
4. **Same-user malware** can edit settings, including approving a command by writing its digest. That user can already run code; the digest exists to protect against edits made outside the approval flow, not against that.
5. **Updates**: until Sparkle is set up, there is no in-app update channel and no automatic security fixes.

## Release checklist

- [ ] Run `./scripts/test.sh`, and it passes.
- [ ] Run `FLUX_SIGN_IDENTITY=… FLUX_NOTARY_PROFILE=… FLUX_VERSION=x.y.z scripts/release.sh`. It ends with "Ready to publish" and an `spctl` "accepted" line.
- [ ] Check `codesign -dv build/Flux.app` shows `flags=0x10000(runtime)` and a Developer ID authority.
- [ ] Open the DMG on a second Mac or user account: it opens without a Gatekeeper warning.
- [ ] Publish the SHA-256 that `release.sh` prints alongside the DMG.
