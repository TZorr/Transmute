//
//  AppModel.swift
//  Transmute
//
//  The kit: sixteen pads (PadModel), which one is selected, the two players,
//  MIDI, the export settings.
//
//  The waveform, the pitch view, the parameter panel, Match, Fit Again,
//  Reset and Export all act on the selected pad; the pads themselves play
//  through the kit player, by a click or a MIDI note, several at once.
//  The Original/Synth comparison (⌘1/⌘2) stays the one-shot player's, for
//  the selected pad.
//
//  Fits run in parallel, as many as the Mac has cores less two (8 on a
//  4 + 6-core machine), the two left for audio and the window; more wait
//  as "queued" (`enqueueFit`). Until 2026-09-26 they ran one at a time,
//  on the grounds that four at once would each take four times as long -
//  true of one core, not of ten; Activity Monitor showed one core busy.
//  It is safe because a fit shares nothing: each builds its own
//  Comparison, the synth is a pure function, and each pad is its own
//  model (the harness fits four drums at once against one at a time).
//
//  MIDI: notes play the pad that has them (DrumKit.learn keeps them unique);
//  Control Changes move whatever they were learnt to - a slider or Pan -
//  on the selected pad (see MIDILearn). Velocity plays no part: the pads
//  are for listening, the files are what gets used (the velocity slots
//  went 2026-09-26). While Learn is
//  armed, the next note or CC is taken as the address instead.
//
//  A .drumkit holds all sixteen pads' drums, pans and notes; no
//  samples (see DrumKit).
//
//  Dropping: pad 1 "Multi" takes up to sixteen files, by name, onto pads
//  1-16 without asking; every other pad one file (DrumKit.dropTargets).
//  Clear empties all sixteen pads' drums and keeps what belongs to the pads'
//  places - pan, note, model choice (PadModel.clear).
//

import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

/// What Learn is waiting for.
enum LearnRequest: Equatable {
    case note(pad: Int)
    case control(String)
}

@Observable
final class AppModel {
    let pads: [PadModel]
    var selected = 0 {
        didSet {
            guard selected != oldValue else { return }
            player.setOriginal(pad.original)
            player.setSynth(pad.synth)
        }
    }

    /// The last export's, save's or open's outcome, beside the export boxes.
    var message: String?
    private(set) var exporting = false
    private(set) var learning: LearnRequest?
    private(set) var midiMap = MIDIMap.load()
    /// The kit file the pads came from or were saved to.
    private(set) var kitName: String?

    let player = OneShotPlayer()
    let kit = KitPlayer()
    /// The Batch Convert window's list and settings.
    @ObservationIgnored private(set) lazy var batch = BatchModel(app: self)
    @ObservationIgnored let midi: MIDIControllerInput

    /// Fits at once: every core but two.
    static let maxParallelFits = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    @ObservationIgnored private var waitingFits: [@MainActor () async -> Void] = []
    @ObservationIgnored private var runningFits = 0

    init(midi: MIDIControllerInput = .shared) {
        self.midi = midi
        pads = (0..<DrumKit.padCount).map { PadModel(index: $0) }
        for pad in pads { pad.app = self }
        midi.onNoteOn = { [weak self] note in self?.handle(note) }
        midi.onControlChange = { [weak self] change in self?.handle(change) }
    }

    var pad: PadModel { pads[selected] }

    // MARK: - Pads

    /// A pad's synth changed: the comparison player follows the selection.
    func padChanged(_ changed: PadModel) {
        guard changed.index == selected else { return }
        player.setSynth(changed.synth)
    }

    /// Files dropped on pad `index` (or chosen for it): see
    /// DrumKit.dropTargets - up to sixteen by name from pad 1, one elsewhere.
    func drop(_ urls: [URL], on index: Int) {
        for target in DrumKit.dropTargets(urls, on: index) {
            pads[target.pad].open(target.url)
        }
        selected = index
    }

    var hasAnyDrum: Bool { pads.contains { !$0.isEmpty } }

    /// Every pad empty; pans, notes and model choices stay.
    func clearAllPads() {
        for pad in pads { pad.clear() }
        message = "Cleared all pads"
    }

    // MARK: - Max level

    /// The ceiling for peaks (Settings), on the 0.5 dB grid; remembered on
    /// this Mac.
    var maxLevelDB: Double = AppModel.storedMaxLevel() {
        didSet {
            let snapped = LevelLimit.snapped(maxLevelDB)
            if snapped != maxLevelDB { maxLevelDB = snapped; return }
            UserDefaults.standard.set(maxLevelDB, forKey: Self.maxLevelKey)
        }
    }

    private static let maxLevelKey = "maxLevelDB"

    private static func storedMaxLevel() -> Double {
        let stored = UserDefaults.standard.object(forKey: maxLevelKey) as? Double
        return LevelLimit.snapped(stored ?? LevelLimit.defaultDB)
    }

    /// "-1.5 dBFS", as the Peak readout writes it.
    var maxLevelLabel: String { String(format: "%.1f dBFS", maxLevelDB) }

    /// Every pad whose peak is above the max level gets its Level lowered
    /// by exactly the overshoot (LevelLimit); the rest stay. A pad still
    /// fitting is left out - the fit's result would replace the change.
    /// No report of which pads moved: the Peak readout shows the result
    /// (the author's call, 2026-09-26). Only skipped pads are mentioned, since
    /// nothing else would show them.
    func limitPeaks() {
        var fitting = 0
        for pad in pads where pad.hasSynth {
            if pad.stage.busy { fitting += 1; continue }
            if let limited = LevelLimit.limited(pad.params, maxDB: maxLevelDB,
                                                rates: [MonoAudio.analysisRate, pad.exportRate]) {
                pad.params = limited
            }
        }
        message = fitting > 0 ? "\(fitting) pad\(fitting == 1 ? "" : "s") still fitting, left as \(fitting == 1 ? "it is" : "they are")" : nil
    }

    /// Tab and Shift-Tab: the next or the previous pad, round from 8 to 1.
    /// Selects only - playing is a click, a note or Space.
    func selectPad(offset: Int) {
        let count = DrumKit.padCount
        selected = ((selected + offset) % count + count) % count
    }

    @ObservationIgnored private var tabMonitor: Any?

    /// Tab and Shift-Tab in the main window, caught before AppKit hands
    /// them out. A menu item with Tab as its key equivalent (the first
    /// version) never fired: without ⌘ the window takes Tab for its own
    /// key-view loop before the menu sees it - the Next Pad item worked
    /// when clicked, the key did nothing ("der rote Rahmen bleibt stehen").
    /// Only in `window`, and never while a text field is being edited, so
    /// Tab still moves between fields in panels and Settings.
    func installTabMonitor(for window: NSWindow) {
        guard tabMonitor == nil else { return }
        tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window, event.keyCode == 48,
                  !(window.firstResponder is NSText) else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard modifiers.isEmpty else { return event }
            self.selectPad(offset: event.modifierFlags.contains(.shift) ? -1 : 1)
            return nil
        }
    }

    /// A click on a pad: select it and play it.
    func tap(_ index: Int) {
        selected = index
        kit.start()
        kit.hit(index)
    }

    func chooseSample(for index: Int? = nil) {
        let target = index ?? selected
        let panel = NSOpenPanel()
        panel.title = "Choose drum samples for pad \(target + 1)"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { drop(panel.urls, on: target) }
    }

    /// Runs `job` as soon as fewer than `maxParallelFits` are running, in
    /// the order they came.
    func enqueueFit(_ job: @escaping @MainActor () async -> Void) {
        waitingFits.append(job)
        startFits()
    }

    private func startFits() {
        while runningFits < Self.maxParallelFits, !waitingFits.isEmpty {
            let job = waitingFits.removeFirst()
            runningFits += 1
            Task { @MainActor in
                await job()
                self.runningFits -= 1
                self.startFits()
            }
        }
    }

    // MARK: - MIDI

    func toggleLearn(_ request: LearnRequest) {
        learning = learning == request ? nil : request
    }

    func forget(_ target: String) {
        midiMap.forget(target)
        midiMap.save()
        if learning == .control(target) { learning = nil }
    }

    func handle(_ note: MIDINoteOn) {
        if case .note(let index) = learning {
            learnNote(note.note, for: index)
            learning = nil
            return
        }
        kit.start()
        for pad in pads where pad.note == note.note {
            kit.hit(pad.index)
        }
    }

    func learnNote(_ note: UInt8, for index: Int) {
        var kitState = DrumKit(pads: pads.map(\.setup))
        kitState.learn(note: note, for: index)
        for (pad, setup) in zip(pads, kitState.pads) { pad.note = setup.note }
    }

    func handle(_ change: MIDIControlChange) {
        if case .control(let target) = learning {
            midiMap.learn(target, from: change)
            midiMap.save()
            learning = nil
            return
        }
        for target in midiMap.targets(for: change) {
            apply(target, position: Double(change.value) / 127)
        }
    }

    /// A learnt control at 0…1 of its travel, on the selected pad.
    func apply(_ target: String, position: Double) {
        let p = pad
        if target == LearnTarget.pan {
            p.pan = -100 + 200 * position
        } else if let spec = ParamSpec.find(target), p.hasSynth {
            if spec.id == "length" { p.params.autoLength = false }
            p.params[keyPath: spec.keyPath] = spec.value(at: position)
        }
    }

    func ccLabel(_ target: String) -> String? { midiMap.controls[target]?.label }

    // MARK: - Kits

    func newKit() {
        for pad in pads { pad.apply(PadSetup(note: DrumKit.defaultNotes[pad.index])) }
        kitName = nil
        message = nil
    }

    func openKit() {
        let panel = NSOpenPanel()
        panel.title = "Open a drum kit"
        panel.allowedContentTypes = [UTType(filenameExtension: DrumKit.fileExtension) ?? .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try DrumKit.read(from: url)
            for (pad, setup) in zip(pads, loaded.pads) { pad.apply(setup) }
            kitName = url.deletingPathExtension().lastPathComponent
            message = "Opened \(url.lastPathComponent)"
        } catch {
            message = "\(url.lastPathComponent) is not a drum kit."
        }
    }

    func saveKit() {
        let panel = NSSavePanel()
        panel.title = "Save the drum kit"
        panel.allowedContentTypes = [UTType(filenameExtension: DrumKit.fileExtension) ?? .json]
        panel.nameFieldStringValue = "\(kitName ?? "Kit").\(DrumKit.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DrumKit(pads: pads.map(\.setup)).write(to: url)
            kitName = url.deletingPathExtension().lastPathComponent
            message = "Saved \(url.lastPathComponent)"
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Parameter files (selected pad)

    func openParams() {
        let panel = NSOpenPanel()
        panel.title = "Open drum parameters onto pad \(selected + 1)"
        panel.allowedContentTypes = [UTType(filenameExtension: DrumParams.fileExtension) ?? .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pad.openParams(url)
    }

    func saveParams() {
        let panel = NSSavePanel()
        panel.title = "Save drum parameters"
        panel.allowedContentTypes = [UTType(filenameExtension: DrumParams.fileExtension) ?? .json]
        panel.nameFieldStringValue = "\(pad.baseName).\(DrumParams.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try pad.params.write(to: url)
            message = "Saved \(url.lastPathComponent)"
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Export (selected pad)

    /// Export format and quality, remembered on this Mac. A new format
    /// starts at its own default quality.
    var exportFormat: OutputFormat = AppModel.storedFormat() {
        didSet {
            guard exportFormat != oldValue else { return }
            UserDefaults.standard.set(exportFormat.rawValue, forKey: Self.formatKey)
            exportQuality = exportFormat.defaultQuality
        }
    }

    var exportQuality: QualityOption = AppModel.storedQuality(for: AppModel.storedFormat()) {
        didSet { UserDefaults.standard.set(exportQuality.label, forKey: Self.qualityKey) }
    }

    private static let formatKey = "exportFormat"
    private static let qualityKey = "exportQuality"

    private static func storedFormat() -> OutputFormat {
        UserDefaults.standard.string(forKey: formatKey).flatMap(OutputFormat.init(rawValue:)) ?? .wav
    }

    private static func storedQuality(for format: OutputFormat) -> QualityOption {
        let label = UserDefaults.standard.string(forKey: qualityKey)
        return format.qualityOptions.first { $0.label == label } ?? format.defaultQuality
    }

    var canExport: Bool { pad.hasSynth && !exporting }

    /// The selected pad's drum, mono, at its source's rate - pan is for
    /// playing, not for the file.
    func export() {
        guard canExport else { return }
        let format = exportFormat, quality = exportQuality, rate = pad.exportRate, p = pad.params
        let panel = NSSavePanel()
        panel.title = "Export \(format.menuTitle) · \(quality.label)"
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "\(pad.baseName) (synth).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        message = "Exporting…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let text: String
            do {
                let audio = DrumSynth.renderAudio(p, sampleRate: rate)
                try Exporter.export(audio, format: format, quality: quality, to: url)
                let khz = rate.truncatingRemainder(dividingBy: 1000) == 0
                    ? String(format: "%.0f kHz", rate / 1000) : String(format: "%.1f kHz", rate / 1000)
                text = "Saved \(url.lastPathComponent) · \(quality.label) · \(khz)"
            } catch {
                text = error.localizedDescription
            }
            await self?.exported(text)
        }
    }

    private func exported(_ text: String) {
        exporting = false
        message = text
    }

    // MARK: - Export Kit

    /// The prefix the last kit export used, remembered on this Mac.
    var kitExportPrefix: String {
        get { UserDefaults.standard.string(forKey: Self.prefixKey) ?? kitName ?? KitExport.defaultPrefix }
        set { UserDefaults.standard.set(newValue, forKey: Self.prefixKey) }
    }

    private static let prefixKey = "kitExportPrefix"

    var canExportKit: Bool { pads.contains(where: \.hasSynth) && !exporting }

    /// Every pad with a drum as "<prefix> <pad number>", in the format and
    /// depth of the export boxes, into a folder chosen in one panel that
    /// also holds the prefix (see KitExport). Files already there with
    /// those names are replaced only after asking.
    func exportKit() {
        guard canExportKit else { return }
        let format = exportFormat, quality = exportQuality
        let items = pads.filter(\.hasSynth).map { KitExport.Item(index: $0.index, params: $0.params, sampleRate: $0.exportRate) }

        let panel = NSOpenPanel()
        panel.title = "Export Kit"
        panel.message = "Choose a folder: each pad with a drum becomes \"<prefix> <pad number>.\(format.fileExtension)\" (\(format.menuTitle) · \(quality.label))."
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let field = NSTextField(string: kitExportPrefix)
        field.placeholderString = KitExport.defaultPrefix
        let label = NSTextField(labelWithString: "Prefix:")
        let example = NSTextField(labelWithString: "")
        example.textColor = .secondaryLabelColor
        example.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let preview = PrefixPreview(field: field, example: example, first: items.first?.index ?? 0,
                                    count: items.count, fileExtension: format.fileExtension)
        field.delegate = preview
        preview.update()
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 8
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let stack = NSStackView(views: [row, example])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = stack
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let prefix = KitExport.cleanPrefix(field.stringValue)
        kitExportPrefix = prefix

        let urls = KitExport.urls(for: items, prefix: prefix, format: format, in: folder)
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = existing.count == 1 ? "Replace \(existing[0].lastPathComponent)?"
                                                    : "Replace \(existing.count) files in \(folder.lastPathComponent)?"
            alert.informativeText = existing.map(\.lastPathComponent).joined(separator: "\n")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        exporting = true
        message = "Exporting kit…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let text: String
            do {
                let written = try KitExport.export(items, prefix: prefix, format: format, quality: quality, to: folder)
                text = "Exported \(written.count) file\(written.count == 1 ? "" : "s") \"\(prefix) …\" to \(folder.lastPathComponent) · \(quality.label)"
            } catch {
                text = error.localizedDescription
            }
            await self?.exported(text)
        }
    }
}

/// Shows under the prefix field what the first file will be called, as
/// it is typed.
private final class PrefixPreview: NSObject, NSTextFieldDelegate {
    let field: NSTextField
    let example: NSTextField
    let first: Int
    let count: Int
    let fileExtension: String

    init(field: NSTextField, example: NSTextField, first: Int, count: Int, fileExtension: String) {
        self.field = field
        self.example = example
        self.first = first
        self.count = count
        self.fileExtension = fileExtension
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    func update() {
        let name = KitExport.fileName(prefix: field.stringValue, index: first, fileExtension: fileExtension)
        example.stringValue = count > 1 ? "\(name) … \(count) files" : name
    }
}
