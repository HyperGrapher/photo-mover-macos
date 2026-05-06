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
    @Published var conflict: FileConflict?
    @Published var alertMessage: String?

    private var moveHistory: [MoveRecord] = []
    private var accessedFolders: Set<URL> = []
    private let imageExtensions = Set(["jpg", "jpeg", "png", "webp"])
    private let maximumUndoCount = 10

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

    func chooseSourceFolder() {
        guard let folder = pickFolder(title: "Choose Source Folder") else { return }
        startAccessing(folder)
        sourceFolder = folder
        currentIndex = 0
        moveHistory.removeAll()
        loadPhotos()
    }

    func addDestinationFolder() {
        guard let folder = pickFolder(title: "Choose Destination Folder") else { return }
        startAccessing(folder)

        guard !destinations.contains(where: { $0.url.standardizedFileURL == folder.standardizedFileURL }) else {
            return
        }

        destinations.append(DestinationFolder(url: folder))
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

    private func pickFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"

        return panel.runModal() == .OK ? panel.url : nil
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

            if viewModel.destinations.isEmpty {
                EmptyDestinationView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.destinations) { destination in
                    DestinationRow(destination: destination)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.moveCurrentPhoto(to: destination)
                        }
                        .disabled(viewModel.currentPhoto == nil)
                }
                .listStyle(.sidebar)
            }

            Divider()

            Button {
                viewModel.addDestinationFolder()
            } label: {
                Label("Add Destination", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(12)
        }
    }
}

struct DestinationRow: View {
    let destination: DestinationFolder

    var body: some View {
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if viewModel.sourceFolder == nil {
                    SourceEmptyState(viewModel: viewModel)
                } else if let photo = viewModel.currentPhoto {
                    PhotoPreview(photo: photo, positionText: viewModel.positionText)
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

struct PhotoPreview: View {
    let photo: PhotoItem
    let positionText: String

    var body: some View {
        VStack(spacing: 14) {
            Text(positionText)
                .font(.headline)
                .foregroundStyle(.secondary)

            Image(nsImage: NSImage(contentsOf: photo.url) ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            Text(photo.filename)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 18)
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
