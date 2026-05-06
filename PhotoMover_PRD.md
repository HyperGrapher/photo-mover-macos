---

Prompt:

Build a macOS photo organizer app using SwiftUI. The app allows users to preview images one at a time from a source folder and move them into destination folders selected from a side panel.

---

App Layout

Use a two-panel layout:
- Left side panel — destination folder list
- Main content area — image preview and controls

---

Source Folder Selection

- On launch, the main content area shows an empty state with a "Choose Source Folder" button.
- Clicking it opens a native NSOpenPanel (folder picker).
- After selection, load all .jpg, .jpeg, and .png (and .webp if possible without adding external library) files directly inside that folder only — do not recurse into subfolders.
- Display a counter showing the total number of images found (e.g. "12 photos").

---

Image Preview

- Show one image at a time, centered and scaled to fit the content area while maintaining aspect ratio.
- Display the current image's filename and its position in the queue (e.g. "3 / 12") below or above the preview.
- After an image is moved, automatically advance to the next image in the queue.
- If there are no more images, show a "All done!" empty state.

---

Destination Folder Panel (Left Side Panel)

- List destination folders vertically, each row showing a folder icon and the folder name.
- Display an image count badge next to each folder name showing how many images have been moved there in this session.
- At the bottom of the panel, show an "Add Destination" button that opens an NSOpenPanel to pick a folder.
- Users can add as many destination folders as needed. Duplicate folders should be ignored.

---

Moving Images

- Clicking a destination folder row moves the currently previewed image to that folder using FileManager.
- Before moving, check if a file with the same name already exists in the destination folder.
  - If a conflict is detected, show an inline modal or sheet that:
    - Displays the conflicting filename.
    - Provides an editable text field pre-filled with the original filename (without extension).
    - Has "Confirm & Move" and "Cancel" buttons.
    - Validates that the new name is not empty and doesn't conflict either.
- After a successful move, update the source folder count and the destination folder's count.

---

Undo

- Maintain a move history stack.
- Display an "Undo" button (toolbar or bottom bar) that reverses the last move: moves the file back to the source folder and restores it in the preview queue.
- The Undo button should be disabled when there is nothing to undo.
- Support at least the last 10 moves in the undo stack.

---

Image Counts

- Source folder label shows remaining image count, updated after each move or undo.
- Each destination folder row shows how many images were moved there this session, updated in real time.

---

Error Handling

- If a file operation fails (e.g. permission denied, file not found), show a non-blocking alert with a clear error message.
- If the source folder becomes inaccessible mid-session, show an error and return to the empty state.

---

Tech Notes

- Use SwiftUI throughout with AppKit interop only where necessary (e.g. NSOpenPanel).
- Xcode 26.3 and Swift 6.2.4
- Use @StateObject / @ObservableObject for app state management.
- Request sandbox-compatible security-scoped bookmarks to maintain folder access across operations.
- Target macOS 13+.

