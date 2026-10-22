# Why Sieve

These are the everyday frustrations with the built-in macOS file browser that Sieve is designed around. Each row
describes behavior anyone can observe by using the system, and what Sieve does instead.

| Frustration | What you notice | Sieve |
|---|---|---|
| Search doesn't match what you typed | System search is built on Spotlight. It matches the *start of words* across names, metadata and file contents. "voice" doesn't find `invoice.pdf`, while "inv" finds documents that merely contain the word somewhere inside. | A literal contains match on the name only, case- and accent-insensitive, with the match highlighted in every result. |
| Results trickle in | Results arrive as the search service gathers them, and folders it skips (e.g. `node_modules`, excluded volumes) never appear. | An in-memory name index kept current through FSEvents. A whole home folder is searched in a few milliseconds, and folders outside it get a temporary index on demand. |
| Extensions disappear | File extensions can be hidden globally or per file, so `report.pdf.app` can pass as a PDF. | Extensions are always shown. There is no setting to hide them. |
| Sorting is hidden and per folder | In column view, sorting lives in a separate options panel and is remembered per folder. | One rule for every folder, always visible in words ("Date Modified · Newest first"), with natural defaults per key. |
| No filtering while browsing | You can't quickly show "only PDFs from the last week" in the folder you're looking at. | One-click kind chips plus date, size and hidden-file filters that apply to browsing and search alike. |
| Synonyms and other languages | Searching "invoice" won't surface `Rechnung_2024.pdf`. | A small local model suggests translations and synonyms. They run through the same literal search and are shown separately, each labelled with the word it matched. |

## Why an index instead of the system search service

A name-only contains query over the whole disk is expensive for a general-purpose metadata service, and it can't
see folders that service excludes. Sieve keeps every name under your home folder and the Applications folders in a
compact columnar buffer: about 60 MB for 900,000 entries. The buffer is built in a few seconds, loads from cache in
about 0.1 s, and stays current through FSEvents. A search is a parallel `memmem` over one contiguous buffer.
