# Third-party notices

Sieve has **no third-party code dependencies**. It is written in Swift against Apple's system frameworks only
(AppKit, SwiftUI, Quick Look, CoreServices/FSEvents, ImageIO, UniformTypeIdentifiers, Combine). They ship with macOS
and are not redistributed.

Used at runtime but **not included** in this repository or the built app:

| What | Where it comes from | Terms |
|---|---|---|
| SF Symbols (toolbar, sidebar and menu icons) | Loaded by name from macOS at runtime | Apple's SF Symbols license: may be used in apps that run on Apple platforms |
| SF Pro (interface text) | The macOS system font | Part of macOS |
| File and folder icons | Requested from macOS (`NSWorkspace`) at runtime | Part of macOS |
| [Ollama](https://ollama.com) (optional) | Installed by the user; Sieve talks to its local HTTP API on `127.0.0.1:11434` | MIT |
| `qwen3.5:2b` model (optional) | Downloaded by Ollama on the user's request | Apache License 2.0 (Qwen team, Alibaba Cloud) |

The app icon is drawn by `scripts/make-icon.swift`, which is part of this repository and covered by its MIT license.
