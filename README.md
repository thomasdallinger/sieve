# Sieve

**A fast, keyboard-first file browser for macOS that finds what you type.**

Sieve treats searching as sifting: every name passes through a literal contains filter in milliseconds, and a small
model running on your own Mac shakes loose the names you didn't think to type. It browses in columns, always shows
the full file name, and puts sorting and filtering in plain sight.

## Highlights

- **Search that matches what you type.** "inv" finds `Rechnung_INVOICE.pdf`, `invoiceService.ts` and `Invoices/`.
  The match is a case- and accent-insensitive *contains* match on the name: no word-prefix rules, and no hits
  from file contents or metadata you can't see. Every match is highlighted. A search over ~900,000 names takes
  2–14 ms.
- **Related names from a local model.** Once the exact matches are on screen, a small model running locally
  through [Ollama](https://ollama.com) suggests translations, synonyms and abbreviations. Searching "rechnung"
  also finds *invoice*, *bill* and *receipt*. Those words go through the same literal filter, so every related
  result visibly matches something, and the row shows which word it matched. Nothing leaves your Mac.
- **Full names, always.** Extensions are part of the name and always shown, drawn in a quieter tone. There is no
  setting to hide them.
- **Columns by default.** Each folder is a card with its own header showing the folder name and item count.
  Arrow keys move between cards, Return renames, Space peeks, ⌘↑ goes up a level.
- **Sorting in plain words.** "Sort: Date Modified · Newest first". Each key starts in the direction people expect
  (names A→Z, dates newest first, sizes largest first), and choosing it again reverses it. Natural order puts
  `file2` before `file10`. One rule applies everywhere, with no hidden per-folder settings.
- **One-click filters.** Kind chips (folders, documents, PDFs, images, video, audio, archives, code, apps;
  ⌘-click to combine), date and size menus, and a hidden-files toggle sit under the toolbar. They apply to
  browsing and to search.
- **Instant everywhere.** A live name index of your home folder and Applications loads in about 0.1 s and stays
  current through FSEvents. Folders are read with `getattrlistbulk`, many entries per system call.

Also included:
- a list view with sortable headers
- a preview pane (Quick Look plus kind, size, dates, dimensions or page count)
- a location pill with breadcrumbs (click it or press ⌘L to type a path, with Tab completion)
- Recent Files
- search scopes with live counts
- tabs, drag & drop, and undo for rename, move, copy and trash
- Copy Path, Open in Terminal, and pinned folders

## Requirements

- macOS 14 or later, Apple silicon or Intel
- Swift 5.10 (the Command Line Tools are enough; Xcode is not needed)
- Optional: [Ollama](https://ollama.com) for related results. Sieve can start it and download the model
  (`qwen3.5:2b-q4_K_M`, 1.9 GB) from the search results or from Settings.

## Build and run

```sh
./scripts/setup-signing.sh   # once: a local signing identity, so folder permissions survive rebuilds
./scripts/build-app.sh       # → dist/Sieve.app
./scripts/install.sh         # build, copy to /Applications, launch
```

During development, `swift run Sieve` runs the app straight from the package.

## Default file viewer

Settings → *Reveal files in Sieve instead of Finder* sets the global `NSFileViewer` default. "Show in Finder" in
other apps and `open -R` in Terminal then show the item selected in a Sieve window. Folders also offer Sieve under
*Open With*.

Finder stays in charge of the desktop, the Trash and opening folders from other apps. macOS refuses to change the
default app for folders, so no other app can take that over. Sieve's own *Reveal in Finder* still goes to Finder;
the first time, macOS asks for permission to control Finder.

If you delete Sieve while the setting is on, run `defaults delete -g NSFileViewer` to give reveals back to Finder.

## Keyboard

| Keys | Action |
|---|---|
| ← → ↑ ↓ | Move between columns and rows |
| Return | Rename (selects the name without its extension) |
| ⌘↓ / ⌘O | Open |
| Space / ⌘Y | Peek (Quick Look) |
| ⌘F | Find by name; ↓ or Return moves into the results, Esc clears |
| ⌘R | Reveal a search result in its folder |
| ⌘[ ⌘] ⌘↑ | Back, forward, up one level |
| ⌘L / ⇧⌘G | Jump to path (Tab completes) |
| ⌘1 / ⌘2 | Columns / List |
| ⇧⌘. | Show hidden files |
| ⌥⌘P | Preview pane |
| ⇧⌘N, ⌘D, ⌘⌫ | New folder, duplicate, move to Trash (⌘Z undoes) |
| ⌘C, ⌘V, ⌥⌘V | Copy, paste, move here |
| ⌥⌘C | Copy path |
| ⌃⌥⌘1…4 | Sort by name, kind, date modified, size |
| ⇧⌘F, ⇧⌘H, ⇧⌘D, ⇧⌘O, ⌥⌘L, ⇧⌘A | Recent Files, Home, Desktop, Documents, Downloads, Applications |
| ⌃⌘T | Pin the selected folder to the sidebar |

## Privacy

- **Local index.** The name index lives in `~/Library/Caches/io.github.thomasdallinger.sieve/` and never leaves
  your Mac.
- **Local model.** Related results come from a model on your own machine (`127.0.0.1`). Only the text you typed is
  sent to it; no file names or contents are.
- **No network calls otherwise.** Sieve has no analytics and no update checks.

## Project layout

```
Sources/SieveCore    UI-free engine: directory reader, name index, matching, sort/filter, local model client
Sources/Sieve         the AppKit app (SwiftUI for the options bar and Settings)
Sources/SieveCheck   checks and benchmarks for SieveCore (`sieve-check`)
scripts/             app bundling, signing, icon
docs/                development notes and the reasoning behind Sieve
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for architecture, checks, benchmarks and the scripted UI runner,
[DESIGN.md](DESIGN.md) for the visual language, and [docs/WHY-SIEVE.md](docs/WHY-SIEVE.md) for the problems Sieve
sets out to solve.

## License

MIT. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Sieve is an independent project and is not affiliated with or endorsed by Apple. macOS, Finder and Quick Look are
trademarks of Apple Inc.
