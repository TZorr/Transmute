//
//  BatchModel.swift
//  Transmute
//
//  The Batch Convert window's state: the dropped files, sorted by name,
//  the model for all of them, the prefix and whether to hold peaks to the
//  max level (see BatchConvert for what one file
//  goes through).
//
//  The fits go through the app's fit queue with the pads' (AppModel
//  .enqueueFit), so a batch uses every core but two and a sample dropped
//  on a pad meanwhile takes its turn rather than a core of its own.
//
//  Where the files go is asked each time Convert is pressed (the author's call,
//  2026-09-27; until then a Choose… row in the window held a folder): a
//  folder panel with New Folder, the way Export Kit asks. The panel gives
//  the sandboxed app the right to write there; the last folder is kept as
//  a bookmark only so the next panel opens where the last batch went.
//  Dropped files are only read.
//
//  Stop cancels what is fitting (the fit checks for it) and whatever has
//  not started; files already written stay.
//

import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

@Observable
final class BatchModel {
    enum Status: Equatable {
        case waiting
        case queued
        case converting(Double)
        case done(String)
        case failed(String)
        case stopped
    }

    struct Item: Identifiable {
        let url: URL
        var status: Status = .waiting
        var id: String { url.standardizedFileURL.path }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    @ObservationIgnored private weak var app: AppModel?

    private(set) var items: [Item] = []
    private(set) var running = false
    private(set) var message: String?
    private(set) var folder: URL?

    /// nil: each sample's analysis chooses.
    var modelChoice: DrumModel? {
        didSet { UserDefaults.standard.set(modelChoice?.rawValue, forKey: Self.modelKey) }
    }

    var prefix: String {
        didSet { UserDefaults.standard.set(prefix, forKey: Self.prefixKey) }
    }

    var limitToMax: Bool {
        didSet { UserDefaults.standard.set(limitToMax, forKey: Self.limitKey) }
    }

    @ObservationIgnored private var tasks: [String: Task<BatchConvert.Result, Error>] = [:]
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var remaining = 0
    @ObservationIgnored private var scopedFolder: URL?

    private static let modelKey = "batchModel"
    private static let prefixKey = "batchPrefix"
    private static let limitKey = "batchLimitToMax"
    private static let folderKey = "batchFolder"

    init(app: AppModel) {
        self.app = app
        let defaults = UserDefaults.standard
        modelChoice = defaults.string(forKey: Self.modelKey).flatMap(DrumModel.init(rawValue:))
        prefix = defaults.string(forKey: Self.prefixKey) ?? BatchConvert.defaultPrefix
        limitToMax = defaults.object(forKey: Self.limitKey) as? Bool ?? true
        folder = Self.resolveFolder()
    }

    // MARK: - List

    /// Files and folders dropped on the window: their audio files join the
    /// list, which stays sorted by name; ones already in it are not added
    /// twice.
    func add(_ urls: [URL]) {
        guard !running else { return }
        let known = Set(items.map(\.id))
        let new = BatchConvert.audioFiles(in: urls).filter { !known.contains($0.standardizedFileURL.path) }
        if new.isEmpty {
            message = "No audio files in what was dropped"
            return
        }
        let all = BatchConvert.sorted(items.map(\.url) + new)
        let statuses = Dictionary(items.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        items = all.map { Item(url: $0, status: statuses[$0.standardizedFileURL.path] ?? .waiting) }
        message = "Added \(new.count) file\(new.count == 1 ? "" : "s")"
    }

    /// The same by an open panel: files, folders or both.
    func chooseFiles() {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.title = "Add to Batch"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func remove(_ id: Item.ID) {
        guard !running else { return }
        items.removeAll { $0.id == id }
    }

    func removeAll() {
        guard !running else { return }
        items = []
        message = nil
    }

    /// The name position `position` in the list is written as.
    func fileName(at position: Int) -> String {
        BatchConvert.fileName(prefix: prefix, position: position, fileExtension: app?.exportFormat.fileExtension ?? "wav")
    }

    // MARK: - Folder

    /// The folder to write to, from a panel that can also make a new one;
    /// nil when cancelled.
    private func askForFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Batch Convert"
        panel.message = "Choose or create the folder the \(items.count) converted file\(items.count == 1 ? " is" : "s are") written to."
        panel.prompt = "Convert"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let folder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        remember(url)
        return url
    }

    private func remember(_ url: URL) {
        folder = url
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.folderKey)
        }
    }

    private static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: folderKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: folderKey)
        }
        return url
    }

    // MARK: - Converting

    var canConvert: Bool { !running && !items.isEmpty && app?.exporting == false }

    /// Asks for the folder, then converts the whole list into it, numbered
    /// in its order; files already there with those names are replaced
    /// only after asking.
    func convert() {
        guard canConvert, let app, let folder = askForFolder() else { return }
        let format = app.exportFormat, quality = app.exportQuality
        let maxDB = limitToMax ? app.maxLevelDB : nil
        let model = modelChoice
        let targets = items.indices.map { folder.appendingPathComponent(fileName(at: $0)) }

        let scoped = folder.startAccessingSecurityScopedResource()
        let existing = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = existing.count == 1 ? "Replace \(existing[0].lastPathComponent)?"
                                                    : "Replace \(existing.count) files in \(folder.lastPathComponent)?"
            alert.informativeText = existing.prefix(20).map(\.lastPathComponent).joined(separator: "\n")
                + (existing.count > 20 ? "\n…" : "")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else {
                if scoped { folder.stopAccessingSecurityScopedResource() }
                return
            }
        }
        scopedFolder = scoped ? folder : nil

        running = true
        stopping = false
        remaining = items.count
        message = "Converting \(items.count) file\(items.count == 1 ? "" : "s")…"
        for position in items.indices {
            items[position].status = .queued
            let item = items[position], target = targets[position]
            app.enqueueFit { [weak self] in
                await self?.run(item, to: target, model: model, maxDB: maxDB, format: format, quality: quality)
            }
        }
    }

    private func run(_ item: Item, to target: URL, model: DrumModel?, maxDB: Double?,
                     format: OutputFormat, quality: QualityOption) async {
        defer { finished() }
        guard !stopping else {
            set(item.id, .stopped)
            return
        }
        set(item.id, .converting(0))
        let id = item.id
        weak let batch = self
        let task = Task.detached(priority: .userInitiated) {
            try BatchConvert.convert(item.url, model: model, maxLevelDB: maxDB, format: format, quality: quality,
                                     to: target) { fraction in
                Task { @MainActor in
                    if case .converting = batch?.status(id) { batch?.set(id, .converting(fraction)) }
                }
            }
        }
        tasks[id] = task
        do {
            let result = try await task.value
            var detail = "\(result.params.model.title) · Match \(String(format: "%.2f", result.score.total)) dB"
                + " · peak \(String(format: "%.1f", result.peakDB)) dBFS"
            if result.loweredDB > 0 { detail += String(format: " (lowered %.1f dB)", result.loweredDB) }
            set(id, .done(detail))
        } catch is CancellationError {
            set(id, .stopped)
        } catch {
            set(id, stopping ? .stopped : .failed(error.localizedDescription))
        }
        tasks[id] = nil
    }

    private func status(_ id: Item.ID) -> Status? { items.first { $0.id == id }?.status }

    private func set(_ id: Item.ID, _ status: Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    private func finished() {
        remaining -= 1
        guard remaining == 0 else { return }
        running = false
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
        let done = items.filter { if case .done = $0.status { true } else { false } }.count
        let failed = items.filter { if case .failed = $0.status { true } else { false } }.count
        var text = "Converted \(done) of \(items.count) to \(folder?.lastPathComponent ?? "the folder")"
        if failed > 0 { text += " · \(failed) failed" }
        if stopping { text += " · stopped" }
        message = text
    }

    /// Cancels the fits running and the ones still waiting.
    func stop() {
        guard running else { return }
        stopping = true
        for task in tasks.values { task.cancel() }
        message = "Stopping…"
    }

    var doneCount: Int {
        items.filter { if case .done = $0.status { true } else { false } }.count
    }
}
