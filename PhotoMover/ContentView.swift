//
//  ContentView.swift
//  PhotoMover
//
//  Created by Burak on 6.05.2026.
//

import AppKit
import Combine
import SwiftUI

struct PhotoItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL

    var filename: String {
        url.lastPathComponent
    }
}

struct DestinationFolder: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var movedCount = 0

    var name: String {
        url.lastPathComponent
    }
}

struct DestinationFolderSet: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var folderPaths: [String]
    var folderBookmarks: [String]

    var urls: [URL] {
        let bookmarkURLs: [URL] = folderBookmarks.compactMap { bookmark in
            guard let data = Data(base64Encoded: bookmark) else { return nil }
            var isStale = false
            return try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }

        return (bookmarkURLs + folderPaths.map { URL(fileURLWithPath: $0) }).reduce(into: []) { result, url in
            guard !result.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
            result.append(url)
        }
    }

    init(id: UUID = UUID(), name: String, folderPaths: [String], folderBookmarks: [String]) {
        self.id = id
        self.name = name
        self.folderPaths = folderPaths
        self.folderBookmarks = folderBookmarks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        folderPaths = try container.decodeIfPresent([String].self, forKey: .folderPaths) ?? []
        folderBookmarks = try container.decodeIfPresent([String].self, forKey: .folderBookmarks) ?? []
    }
}

struct MoveRecord {
    let sourceURL: URL
    let destinationURL: URL
    let destinationFolderID: DestinationFolder.ID
    let originalIndex: Int
}

struct FileConflict: Identifiable {
    let id = UUID()
    let photo: PhotoItem
    let destination: DestinationFolder
    let originalIndex: Int
    var proposedName: String
    var message: String?

    var fileExtension: String {
        photo.url.pathExtension
    }

    var filename: String {
        photo.filename
    }
}

@MainActor
final class PhotoMoverViewModel: ObservableObject {
    @Published var sourceFolder: URL?
    @Published var photos: [PhotoItem] = []
    @Published var currentIndex = 0
    @Published var destinations: [DestinationFolder] = []
    @Published var savedSets: [DestinationFolderSet] = []
    @Published var activeSetID: DestinationFolderSet.ID?
    @Published var conflict: FileConflict?
    @Published var alertMessage: String?

    private var moveHistory: [MoveRecord] = []
    private var accessedFolders: Set<URL> = []
    private let imageExtensions = Set(["jpg", "jpeg", "png", "webp"])
    private let maximumUndoCount = 10
    private let savedSetsKey = "destinationFolderSets"

    init() {
        loadSavedSets()
    }

    var currentPhoto: PhotoItem? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return photos[currentIndex]
    }

    var remainingCount: Int {
        photos.count
    }

    var sourceCountText: String {
        "\(remainingCount) \(remainingCount == 1 ? "photo" : "photos")"
    }

    var positionText: String {
        guard !photos.isEmpty else { return "" }
        return "\(currentIndex + 1) / \(photos.count)"
    }

    var canUndo: Bool {
        !moveHistory.isEmpty
    }

    var canGoToPreviousPhoto: Bool {
        currentIndex > 0
    }

    var canGoToNextPhoto: Bool {
        currentIndex < photos.count - 1
    }

    var destinationSetButtonTitle: String {
        savedSets.isEmpty ? "Save Set" : "Create New Set"
    }

    var canUseDestinationSetButton: Bool {
        !savedSets.isEmpty || !destinations.isEmpty
    }

    func chooseSourceFolder() {
        guard let folder = pickFolder(title: "Choose Source Folder") else { return }
        startAccessing(folder)
        sourceFolder = folder
        currentIndex = 0
        moveHistory.removeAll()
        loadPhotos()
    }

    func addDestinationFolder() {
        addDestinationFolders()
    }

    func addDestinationFolders() {
        let folders = pickFolders(title: "Choose Destination Folders", allowsMultipleSelection: true)
        guard !folders.isEmpty else { return }

        for folder in folders {
            startAccessing(folder)

            guard !destinations.contains(where: { $0.url.standardizedFileURL == folder.standardizedFileURL }) else {
                continue
            }

            destinations.append(DestinationFolder(url: folder))
        }

        updateActiveSetIfNeeded()
    }

    func goToPreviousPhoto() {
        guard canGoToPreviousPhoto else { return }
        currentIndex -= 1
    }

    func goToNextPhoto() {
        guard canGoToNextPhoto else { return }
        currentIndex += 1
    }

    func saveCurrentDestinationsAsSet() {
        guard !destinations.isEmpty else {
            alertMessage = "Add destination folders before saving a set."
            return
        }

        guard let name = promptForSetName(title: "Save Destination Set", message: "Name this folder set.") else {
            return
        }

        let set = DestinationFolderSet(
            name: name,
            folderPaths: destinationPaths(),
            folderBookmarks: destinationBookmarks()
        )
        savedSets.append(set)
        activeSetID = set.id
        persistSavedSets()
    }

    func createEmptyDestinationSet() {
        guard let name = promptForSetName(title: "Create New Set", message: "Name this folder set.") else {
            return
        }

        let set = DestinationFolderSet(name: name, folderPaths: [], folderBookmarks: [])
        savedSets.append(set)
        activeSetID = set.id
        destinations.removeAll()
        persistSavedSets()
    }

    func handleDestinationSetButton() {
        if savedSets.isEmpty {
            saveCurrentDestinationsAsSet()
        } else {
            createEmptyDestinationSet()
        }
    }

    func loadDestinationSet(_ set: DestinationFolderSet) {
        activeSetID = set.id
        destinations = set.urls.map { url in
            startAccessing(url)
            return DestinationFolder(url: url)
        }
    }

    func loadDestinationSet(id: DestinationFolderSet.ID?) {
        guard let id else {
            activeSetID = nil
            destinations.removeAll()
            return
        }

        guard let set = savedSets.first(where: { $0.id == id }) else { return }
        loadDestinationSet(set)
    }

    func deleteActiveDestinationSet() {
        guard let activeSetID,
              let set = savedSets.first(where: { $0.id == activeSetID }) else {
            return
        }

        deleteDestinationSet(set)
    }

    func deleteDestinationSet(_ set: DestinationFolderSet) {
        let deletedActiveSet = activeSetID == set.id
        let deletedIndex = savedSets.firstIndex(where: { $0.id == set.id })
        savedSets.removeAll { $0.id == set.id }

        if deletedActiveSet {
            if let nextSet = nextSetAfterDeletion(from: deletedIndex) {
                loadDestinationSet(nextSet)
            } else {
                activeSetID = nil
                destinations.removeAll()
            }
        }

        persistSavedSets()
    }

    func removeDestination(_ destination: DestinationFolder) {
        destinations.removeAll { $0.id == destination.id }
        updateActiveSetIfNeeded()
    }

    func moveCurrentPhoto(to destination: DestinationFolder) {
        guard let photo = currentPhoto else { return }
        let destinationURL = destination.url.appendingPathComponent(photo.filename)
        let originalIndex = currentIndex

        guard fileExists(at: photo.url) else {
            handleSourceAccessFailure()
            return
        }

        if fileExists(at: destinationURL) {
            conflict = FileConflict(
                photo: photo,
                destination: destination,
                originalIndex: originalIndex,
                proposedName: photo.url.deletingPathExtension().lastPathComponent
            )
            return
        }

        performMove(photo: photo, to: destination, finalURL: destinationURL, originalIndex: originalIndex)
    }

    func confirmConflictMove() {
        guard var conflict else { return }

        let trimmedName = conflict.proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            conflict.message = "Enter a filename before moving."
            self.conflict = conflict
            return
        }

        let finalURL = conflict.destination.url
            .appendingPathComponent(trimmedName)
            .appendingPathExtension(conflict.fileExtension)

        guard finalURL.standardizedFileURL != conflict.photo.url.standardizedFileURL else {
            conflict.message = "Choose a different filename."
            self.conflict = conflict
            return
        }

        guard !fileExists(at: finalURL) else {
            conflict.message = "A file with that name already exists in the destination."
            self.conflict = conflict
            return
        }

        performMove(
            photo: conflict.photo,
            to: conflict.destination,
            finalURL: finalURL,
            originalIndex: conflict.originalIndex
        )
        self.conflict = nil
    }

    func cancelConflictMove() {
        conflict = nil
    }

    func undoLastMove() {
        guard let record = moveHistory.popLast() else { return }

        do {
            if fileExists(at: record.sourceURL) {
                throw PhotoMoverError.destinationAlreadyExists(record.sourceURL.lastPathComponent)
            }

            try FileManager.default.moveItem(at: record.destinationURL, to: record.sourceURL)
            let insertionIndex = min(record.originalIndex, photos.count)
            photos.insert(PhotoItem(url: record.sourceURL), at: insertionIndex)
            currentIndex = insertionIndex

            if let destinationIndex = destinations.firstIndex(where: { $0.id == record.destinationFolderID }) {
                destinations[destinationIndex].movedCount = max(0, destinations[destinationIndex].movedCount - 1)
            }
        } catch {
            alertMessage = "Could not undo move: \(error.localizedDescription)"
        }
    }

    private func loadPhotos() {
        guard let sourceFolder else { return }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: sourceFolder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            photos = contents
                .filter { url in
                    imageExtensions.contains(url.pathExtension.lowercased())
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map(PhotoItem.init(url:))
        } catch {
            alertMessage = "Could not read the source folder: \(error.localizedDescription)"
            resetSource()
        }
    }

    private func performMove(photo: PhotoItem, to destination: DestinationFolder, finalURL: URL, originalIndex: Int) {
        do {
            try FileManager.default.moveItem(at: photo.url, to: finalURL)

            if let photoIndex = photos.firstIndex(of: photo) {
                photos.remove(at: photoIndex)
                currentIndex = min(photoIndex, max(photos.count - 1, 0))
            }

            if let destinationIndex = destinations.firstIndex(where: { $0.id == destination.id }) {
                destinations[destinationIndex].movedCount += 1
            }

            moveHistory.append(MoveRecord(
                sourceURL: photo.url,
                destinationURL: finalURL,
                destinationFolderID: destination.id,
                originalIndex: originalIndex
            ))

            if moveHistory.count > maximumUndoCount {
                moveHistory.removeFirst(moveHistory.count - maximumUndoCount)
            }
        } catch {
            alertMessage = "Could not move \(photo.filename): \(error.localizedDescription)"
        }
    }

    private func loadSavedSets() {
        guard let data = UserDefaults.standard.data(forKey: savedSetsKey) else { return }
        savedSets = (try? JSONDecoder().decode([DestinationFolderSet].self, from: data)) ?? []
    }

    private func persistSavedSets() {
        guard let data = try? JSONEncoder().encode(savedSets) else { return }
        UserDefaults.standard.set(data, forKey: savedSetsKey)
    }

    private func updateActiveSetIfNeeded() {
        guard let activeSetID,
              let index = savedSets.firstIndex(where: { $0.id == activeSetID }) else {
            return
        }

        savedSets[index].folderPaths = destinationPaths()
        savedSets[index].folderBookmarks = destinationBookmarks()
        persistSavedSets()
    }

    private func nextSetAfterDeletion(from deletedIndex: Int?) -> DestinationFolderSet? {
        guard !savedSets.isEmpty else { return nil }
        guard let deletedIndex else { return savedSets.first }
        return savedSets[min(deletedIndex, savedSets.count - 1)]
    }

    private func destinationPaths() -> [String] {
        destinations.map { $0.url.standardizedFileURL.path }
    }

    private func destinationBookmarks() -> [String] {
        destinations.compactMap { destination in
            try? destination.url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ).base64EncodedString()
        }
    }

    private func promptForSetName(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = "Folder set name"
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled Set" : name
    }

    private func pickFolder(title: String) -> URL? {
        pickFolders(title: title, allowsMultipleSelection: false).first
    }

    private func pickFolders(title: String, allowsMultipleSelection: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canCreateDirectories = false
        panel.prompt = "Choose"

        return panel.runModal() == .OK ? panel.urls : []
    }

    private func startAccessing(_ folder: URL) {
        if folder.startAccessingSecurityScopedResource() {
            accessedFolders.insert(folder)
        }
    }

    private func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func handleSourceAccessFailure() {
        alertMessage = "The source folder is no longer accessible. Choose a source folder to continue."
        resetSource()
    }

    private func resetSource() {
        sourceFolder = nil
        photos = []
        currentIndex = 0
        moveHistory.removeAll()
        conflict = nil
    }
}

enum PhotoMoverError: LocalizedError {
    case destinationAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .destinationAlreadyExists(let filename):
            "A file named \(filename) already exists in the source folder."
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = PhotoMoverViewModel()

    var body: some View {
        NavigationSplitView {
            DestinationSidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            MainPhotoView(viewModel: viewModel)
        }
        .frame(minWidth: 900, minHeight: 620)
        .alert("Photo Mover", isPresented: alertBinding) {
            Button("OK", role: .cancel) {
                viewModel.alertMessage = nil
            }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        .sheet(item: $viewModel.conflict) { conflict in
            ConflictSheet(viewModel: viewModel, conflict: conflict)
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )
    }
}

struct DestinationSidebar: View {
    @ObservedObject var viewModel: PhotoMoverViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Destinations")
                    .font(.headline)
                Text(viewModel.sourceCountText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            SavedSetPicker(viewModel: viewModel)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            List {
                Section("Folders") {
                    if viewModel.destinations.isEmpty {
                        EmptyDestinationView()
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(viewModel.destinations) { destination in
                            DestinationRow(
                                destination: destination,
                                moveAction: { viewModel.moveCurrentPhoto(to: destination) },
                                deleteAction: { viewModel.removeDestination(destination) }
                            )
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(spacing: 8) {
                Button {
                    viewModel.addDestinationFolders()
                } label: {
                    Label("Add Destinations", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.handleDestinationSetButton()
                } label: {
                    Label(viewModel.destinationSetButtonTitle, systemImage: viewModel.savedSets.isEmpty ? "tray.and.arrow.down" : "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canUseDestinationSetButton)
            }
            .padding(12)
        }
    }
}

struct SavedSetPicker: View {
    @ObservedObject var viewModel: PhotoMoverViewModel

    var body: some View {
        HStack(spacing: 8) {
            Picker("Saved Sets", selection: activeSetBinding) {
                Text("No saved set").tag(Optional<DestinationFolderSet.ID>.none)
                ForEach(viewModel.savedSets) { set in
                    Text(set.name).tag(Optional(set.id))
                }
            }
            .labelsHidden()
            .disabled(viewModel.savedSets.isEmpty)

            Button(role: .destructive) {
                viewModel.deleteActiveDestinationSet()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(viewModel.activeSetID == nil)
            .help("Delete set")
        }
    }

    private var activeSetBinding: Binding<DestinationFolderSet.ID?> {
        Binding(
            get: { viewModel.activeSetID },
            set: { viewModel.loadDestinationSet(id: $0) }
        )
    }
}

struct DestinationRow: View {
    let destination: DestinationFolder
    let moveAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: moveAction) {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.blue)
                        .frame(width: 18)

                    Text(destination.name)
                        .lineLimit(1)

                    Spacer()

                    Text("\(destination.movedCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: deleteAction) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove destination")
        }
        .padding(.vertical, 6)
    }
}

struct EmptyDestinationView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No destinations")
                .font(.headline)
            Text("Add folders, then click one to move the current photo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}

struct MainPhotoView: View {
    @ObservedObject var viewModel: PhotoMoverViewModel
    @State private var zoomRequest: ZoomRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if viewModel.sourceFolder == nil {
                    SourceEmptyState(viewModel: viewModel)
                } else if let photo = viewModel.currentPhoto {
                    PhotoPreview(photo: photo, zoomRequest: zoomRequest)
                } else {
                    DoneState(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.sourceFolder?.lastPathComponent ?? "Photo Mover")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(viewModel.sourceFolder == nil ? "Choose a source folder to begin." : viewModel.sourceCountText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(viewModel.positionText)
                .font(.headline)
                .foregroundStyle(.secondary)
                .opacity(viewModel.currentPhoto == nil ? 0 : 1)

            Spacer()

            Button {
                viewModel.chooseSourceFolder()
            } label: {
                Label("Choose Source Folder", systemImage: "folder")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Button {
                viewModel.undoLastMove()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)

            Button {
                viewModel.goToPreviousPhoto()
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(!viewModel.canGoToPreviousPhoto)

            Button {
                viewModel.goToNextPhoto()
            } label: {
                Label("Skip", systemImage: "chevron.right")
            }
            .disabled(!viewModel.canGoToNextPhoto)

            Spacer()

            HStack(spacing: 6) {
                Button {
                    zoomRequest = ZoomRequest(scale: 0.8)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out")
                .disabled(viewModel.currentPhoto == nil)

                Button {
                    zoomRequest = ZoomRequest(scale: 1.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in")
                .disabled(viewModel.currentPhoto == nil)
            }

            Spacer()

            Text(viewModel.currentPhoto?.filename ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

struct SourceEmptyState: View {
    @ObservedObject var viewModel: PhotoMoverViewModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("Choose a source folder")
                .font(.title2.weight(.semibold))
            Button {
                viewModel.chooseSourceFolder()
            } label: {
                Label("Choose Source Folder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct DoneState: View {
    @ObservedObject var viewModel: PhotoMoverViewModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 54))
                .foregroundStyle(.green)
            Text("All done!")
                .font(.title2.weight(.semibold))
            Button {
                viewModel.chooseSourceFolder()
            } label: {
                Label("Choose Another Source", systemImage: "folder")
            }
        }
    }
}

struct ZoomRequest: Equatable {
    let id = UUID()
    let scale: CGFloat
}

struct PhotoPreview: View {
    let photo: PhotoItem
    let zoomRequest: ZoomRequest?

    var body: some View {
        ZoomableImageView(url: photo.url, zoomRequest: zoomRequest)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
        .padding(.vertical, 0)
    }
}

struct ZoomableImageView: NSViewRepresentable {
    let url: URL
    let zoomRequest: ZoomRequest?

    func makeNSView(context: Context) -> ZoomableImageScrollView {
        let scrollView = ZoomableImageScrollView()
        scrollView.loadImage(from: url)
        return scrollView
    }

    func updateNSView(_ nsView: ZoomableImageScrollView, context: Context) {
        nsView.loadImage(from: url)

        if let zoomRequest, context.coordinator.lastZoomRequestID != zoomRequest.id {
            context.coordinator.lastZoomRequestID = zoomRequest.id
            nsView.zoom(by: zoomRequest.scale)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastZoomRequestID: UUID?
    }
}

final class ZoomableImageScrollView: NSScrollView {
    private let canvasView = NSView()
    private let imageView = NSImageView()
    private var loadedURL: URL?
    private var zoom: CGFloat = 1
    private var gestureStartZoom: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        usesPredominantAxisScrolling = false
        borderType = .noBorder

        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        canvasView.addSubview(imageView)
        documentView = canvasView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateDocumentFrame()
    }

    func loadImage(from url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        imageView.image = NSImage(contentsOf: url)
        zoom = 1
        gestureStartZoom = 1
        updateDocumentFrame()
    }

    override func magnify(with event: NSEvent) {
        if event.phase == .began {
            gestureStartZoom = zoom
        }

        let nextZoom = gestureStartZoom * (1 + event.magnification)
        setZoom(nextZoom, centeredAt: convert(event.locationInWindow, from: nil))

        if event.phase == .ended || event.phase == .cancelled {
            gestureStartZoom = zoom
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }

        setZoom(zoom * (1 - event.scrollingDeltaY / 300), centeredAt: convert(event.locationInWindow, from: nil))
    }

    func zoom(by scale: CGFloat) {
        let centerPoint = NSPoint(x: bounds.midX, y: bounds.midY)
        setZoom(zoom * scale, centeredAt: centerPoint)
    }

    private func setZoom(_ nextZoom: CGFloat, centeredAt pointInScrollView: NSPoint) {
        guard let documentView else { return }

        let oldVisibleRect = contentView.bounds
        let anchorInDocument = convert(pointInScrollView, to: documentView)
        let oldSize = documentView.bounds.size

        zoom = min(max(nextZoom, 0.2), 8)
        updateDocumentFrame()

        let newSize = documentView.bounds.size
        let scaleX = oldSize.width > 0 ? newSize.width / oldSize.width : 1
        let scaleY = oldSize.height > 0 ? newSize.height / oldSize.height : 1
        let viewportPoint = convert(pointInScrollView, to: contentView)
        let newOrigin = NSPoint(
            x: anchorInDocument.x * scaleX - viewportPoint.x,
            y: anchorInDocument.y * scaleY - viewportPoint.y
        )

        contentView.scroll(to: boundedScrollOrigin(newOrigin, visibleSize: oldVisibleRect.size, documentSize: newSize))
        reflectScrolledClipView(contentView)
    }

    private func updateDocumentFrame() {
        guard let image = imageView.image else {
            canvasView.frame = bounds
            imageView.frame = bounds
            return
        }

        let viewportSize = contentView.bounds.size
        guard image.size.width > 0, image.size.height > 0, viewportSize.width > 0, viewportSize.height > 0 else {
            return
        }

        let fitScale = min(viewportSize.width / image.size.width, viewportSize.height / image.size.height)
        let imageWidth = image.size.width * fitScale * zoom
        let imageHeight = image.size.height * fitScale * zoom
        let canvasWidth = max(viewportSize.width, imageWidth)
        let canvasHeight = max(viewportSize.height, imageHeight)

        canvasView.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        imageView.frame = NSRect(
            x: (canvasWidth - imageWidth) / 2,
            y: (canvasHeight - imageHeight) / 2,
            width: imageWidth,
            height: imageHeight
        )
    }

    private func boundedScrollOrigin(_ origin: NSPoint, visibleSize: NSSize, documentSize: NSSize) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, 0), max(documentSize.width - visibleSize.width, 0)),
            y: min(max(origin.y, 0), max(documentSize.height - visibleSize.height, 0))
        )
    }
}

struct ConflictSheet: View {
    @ObservedObject var viewModel: PhotoMoverViewModel
    @State private var proposedName: String

    private let conflict: FileConflict

    init(viewModel: PhotoMoverViewModel, conflict: FileConflict) {
        self.viewModel = viewModel
        self.conflict = conflict
        _proposedName = State(initialValue: conflict.proposedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("File already exists")
                    .font(.title3.weight(.semibold))
                Text(conflict.filename)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("New filename")
                    .font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    TextField("Filename", text: $proposedName)
                    Text(".\(conflict.fileExtension)")
                        .foregroundStyle(.secondary)
                }
            }

            if let message = viewModel.conflict?.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    viewModel.cancelConflictMove()
                }
                Button("Confirm & Move") {
                    viewModel.conflict?.proposedName = proposedName
                    viewModel.confirmConflictMove()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 430)
    }
}
