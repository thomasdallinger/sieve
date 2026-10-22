# Development

## Architecture

**SieveCore** has no UI and is checked by `sieve-check`.

- `DirectoryReader` reads one folder with `getattrlistbulk(2)`: names, types, dates, flags and sizes come back
  in bulk. `DirectoryListing` turns them into `FileItem`s for the views.
- `FileIndex` is the filename index. Its storage is columnar: parallel arrays for parent, offsets, flags,
  size and mtime, plus two byte buffers holding original and folded names, with each folded name followed by
  a 0 byte. Invariants:
  - A child's id is always larger than its parent's. This lets path reconstruction, death propagation,
    compaction and cache loading each run in one forward pass.
  - Entries are never removed in place. They are flagged dead, and `propagateDeath` marks the whole subtree.
    `compact()` rewrites the arrays once a fifth of the index is dead.
  - Search holds the read lock, splits the folded buffer into chunks and runs `memmem` over each in
    parallel. A binary search on `foldStart` maps each hit back to its entry. Ancestors are then checked for
    dead, hidden and scope.
- `SearchQuery` handles whitespace-separated tokens, all of which must appear in any order, and quoted
  phrases. Scoring prefers exact name, then exact stem, then prefix, then word boundary, then mid-word. Shorter,
  shallower and more recently modified names win ties.
- `IndexManager` loads the cache, replays FSEvents since the stored event id, keeps watching, and saves every 5
  minutes and on quit. Folders outside the index (other volumes, `~/Library`) get a short-lived index that
  is built on demand and searched while it builds.
- `LocalModel` is the Ollama client. A few-shot prompt asks only for *other* words a file name might contain.
  The output is parsed leniently (small models wrap JSON in code fences), filtered for generic words and words
  the literal query already covers, and cached per query.

**Sieve** is the app. It uses AppKit for everything performance-sensitive (column, list and search tables,
sidebar, path bar) and SwiftUI for the options bar and Settings. `Preferences` holds the global sort, filter
and view options; a browser window observes it through Combine.

## Checks and benchmarks

```sh
swift build -c release --product sieve-check
.build/release/sieve-check            # correctness checks on a temporary tree
.build/release/sieve-check --bench    # also index + search your home folder, list/sort timings
.build/release/sieve-check --expand rechnung "vacation photos"   # prompt tuning against the local model
```

Numbers on an M3 Pro (36 GB), home + /Applications with 907k entries:

| | |
|---|---|
| Full index build | 3.6 s |
| Cache load / save | 97 ms / 53 ms (60 MB) |
| Search "invoice" / "2024 pdf" / "e" | 2.0 / 1.9 / 12 ms |
| Recent files (200) | 3.7 ms |
| List 20,000-file folder (warm) / sort it | 29 ms / 8.5 ms |
| Navigate within a tree (reused columns) | ~14–25 ms |
| Navigate to a new root (new columns, full redraw) | ~45 ms median |
| AI expansion (`qwen3.5:2b-q4_K_M`, warm) | ~1.1–1.4 s |

## Scripted UI runs

UI verification doesn't need Screen Recording permission. Debug builds, and release builds compiled with
`-DSCENARIO`, read a scenario file and render windows in-process:

```sh
swift build
SIEVE_SCENARIO=steps.txt .build/debug/Sieve

# Release timings without touching the shipping build:
swift build -c release -Xswiftc -DSCENARIO --build-path .build/scenario
SIEVE_SCENARIO=steps.txt .build/scenario/release/Sieve
```

```
wait 2
go ~/Downloads
search invoice
wait 3
dump                      # title, status bar, selection, columns, visible rows
shot /tmp/search.png      # renders the window to PNG
bench ~/IdeaProjects      # navigate + layout + draw time
quit
```

Commands are documented in `Sources/Sieve/DebugScenario.swift`. Destructive actions (`action moveToTrash`,
`paste`, …) only run when everything they touch is under `/tmp`. Quick Look's remote views don't appear in
in-process snapshots.

`SIEVE_LOG_EVENTS=1` prints every FSEvents batch the index receives.

## Index cache

The cache is stored at `~/Library/Caches/io.github.thomasdallinger.sieve/index.bin`. It is rejected
automatically when the roots or exclusions change; Settings → Apply and Rebuild Index deletes and rebuilds it.
