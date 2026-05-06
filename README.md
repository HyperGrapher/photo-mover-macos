# 📁 PhotoSort

A clean, keyboard-friendly macOS app for quickly sorting photos into destination folders — one image at a time.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)
![License](https://img.shields.io/badge/license-MIT-green)

---

## Overview

PhotoSort is a native macOS application built with SwiftUI that streamlines photo organization. Instead of dragging and dropping files in Finder, you pick a source folder, and the app presents each photo one at a time. A single click on a destination folder in the side panel moves the image instantly — making large photo sorting sessions fast and focused.

---

## Screenshots

> _Add your screenshots here_

---

## Features

- **One-at-a-time preview** — Images are displayed full-size, centered, and scaled to fit. Filename and progress counter (e.g. `3 / 12`) are shown at all times.
- **Side panel destinations** — Add as many destination folders as you need. Each folder shows a live count of images moved there this session.
- **Conflict resolution** — If a file with the same name already exists in the destination, a rename sheet appears before the move is committed.
- **Undo support** — Mistakenly moved a photo? Hit Undo to move it back. The last 10 moves are tracked.
- **Live counters** — Source folder remaining count and per-destination counts update in real time after every move or undo.
- **No subfolders** — Only images directly inside the source folder are loaded (`.jpg`, `.jpeg`, `.png`). Subfolders are intentionally ignored.
- **Sandboxed & secure** — Uses security-scoped bookmarks for persistent folder access without requiring full disk permission.

---

## Requirements

| Requirement | Version |
|---|---|
| macOS | 13.0 Ventura or later |
| Xcode | 15.0 or later |
| Swift | 5.9 or later |

---

## Installation

### Clone & Build

```bash
git clone https://github.com/yourusername/PhotoSort.git
cd PhotoSort
open PhotoSort.xcodeproj
```

Then press `Cmd + R` in Xcode to build and run.

### Download

Download the latest release from the [Releases](https://github.com/yourusername/PhotoSort/releases) page and move `PhotoSort.app` to your `/Applications` folder.

---

## Usage

1. **Launch the app** — the main area shows an empty state with a "Choose Source Folder" button.
2. **Select a source folder** — only `.jpg`, `.jpeg`, and `.png` files at the top level are loaded.
3. **Add destination folders** — click "Add Destination" at the bottom of the left panel to pick folders. Add as many as you need.
4. **Sort** — the first image is previewed. Click any destination folder to move the current image there.
5. **Handle conflicts** — if a filename already exists in the destination, a rename sheet appears. Edit the name and confirm.
6. **Undo** — click the Undo button (or press `Cmd + Z`) to reverse the last move.
7. **Finish** — when all images are sorted, an "All done!" screen is shown.

---

## Architecture

The app follows a straightforward SwiftUI + AppKit interop architecture:

```
PhotoSort/
├── App/
│   └── PhotoSortApp.swift          # App entry point
├── Views/
│   ├── ContentView.swift           # Root two-panel layout
│   ├── ImagePreviewView.swift      # Main image preview area
│   ├── DestinationPanelView.swift  # Left side panel
│   └── RenameSheetView.swift       # Conflict rename modal
├── ViewModel/
│   └── PhotoSortViewModel.swift    # @ObservableObject app state
└── Helpers/
    └── FileHelper.swift            # FileManager operations
```

**State management:** `@StateObject` / `@ObservableObject` with a single `PhotoSortViewModel` driving the entire UI.

**File access:** `NSOpenPanel` for folder selection, `NSFileCoordinator` + security-scoped bookmarks for sandbox-compatible file operations.

---

## Contributing

Contributions are welcome! Please open an issue first to discuss what you'd like to change.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.