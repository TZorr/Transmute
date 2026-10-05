//
//  PadModel.swift
//  Transmute
//
//  One pad: a sample, what the analysis made of it, the parameters being
//  edited, the synth they render - everything the whole app held when it
//  had one drum - plus what makes a pad playable: pan and a MIDI note.
//
//  Dropping a file on a pad runs everything at once - decode, analyse, fit
//  - with no button in between. Decoding and analysis start straight away;
//  the fit, a few seconds of full CPU, waits its turn in the app's fit queue
//  (AppModel.enqueueFit), so four samples dropped at once fit one after
//  another and each pad shows where it is. The Analyzer's first guess is
//  on the pad and playable while it waits.
//
//  Every edit renders the synth again, straight away and on the main
//  thread: a render is about a millisecond and a score a few more, so a
//  slider drag stays live. The Match figure is recomputed with it. The
//  pad's playable copy (its PadVoiceSet) is rebuilt in the background
//  100 ms after the last change.
//
//  The model (Kick / Tom, Snare, Hi-Hat or Modal) comes from the analysis's
//  suggestion, or from the pad's own choice (`modelChoice`), which can be
//  made before any sample is dropped - the author's request, 2026-09-26: a pad set
//  to Snare analyses whatever lands on it as a snare. Choosing a model on
//  a loaded pad analyses the sample again as that model and fits it
//  (`setModel`) - a snare's parameters are not a kick's with two more;
//  Automatic goes back to the suggestion.
//
//  Background jobs carry a generation number: a file dropped while the last
//  one is still being fitted bumps it, and whatever arrives with an older
//  number is thrown away.
//
//  A pad shows its sample's name, or its parameter file's, unless it has
//  been renamed (`rename`); that name is what a saved kit and an export
//  carry too.
//
//  A pad can change places: dragging one pad onto another swaps the two
//  objects in AppModel.pads (`moved(to:)` gives each its new index). Every
//  job holds its pad, not a number, so a fit that ends after the move lands
//  on the drum's new place.
//

import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

enum Stage: Equatable {
    case empty
    case decoding
    case analysing
    case queued
    case fitting(Double)
    case done
    case failed(String)

    var busy: Bool {
        switch self {
        case .decoding, .analysing, .queued, .fitting: true
        default: false
        }
    }
}

@Observable
final class PadModel {
    /// The pad's place, 0-15; changes when pads are swapped (AppModel
    /// .swapPads).
    private(set) var index: Int
    @ObservationIgnored weak var app: AppModel?

    private(set) var url: URL?
    private(set) var sourceInfo: SourceInfo?
    /// The decoded file, kept for analysing it again as another model.
    @ObservationIgnored private var source: MonoAudio?
    private(set) var analysis: Analysis?
    private(set) var stage: Stage = .empty
    /// The last fit's result - what Reset returns to.
    private(set) var fitted: FitReport?
    /// The synth as it stands, at the analysis rate.
    private(set) var synth: MonoAudio?
    /// How close `params` are to the original; nil without one.
    private(set) var score: MatchScore?
    /// Where the parameters came from, when they came from a file or a kit.
    private(set) var paramsName: String?
    /// A name given by Rename; shown, saved and exported instead of the
    /// others. Kept when the model changes, dropped with the drum: a new
    /// sample, a parameter file, a kit or Clear.
    private(set) var customName: String?

    var params = DrumParams() {
        didSet {
            guard params != oldValue else { return }
            renderSynth()
        }
    }

    /// −100 … +100; playback only.
    var pan: Double = 0 {
        didSet { if pan != oldValue { scheduleVoices() } }
    }

    /// The MIDI note that plays it; set by the app, which keeps notes unique.
    var note: UInt8?

    /// The model the next sample is analysed as; nil lets the analysis
    /// choose. Belongs to the pad's place, like pan: clearing the pad keeps
    /// it.
    var modelChoice: DrumModel?

    /// Limit was pressed while this pad was still fitting: its peak is
    /// held to the max level as soon as the fit is done (AppModel
    /// .limitPeaks). A new sample, a cleared pad or a failed fit drops it.
    @ObservationIgnored var limitPending = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var comparison: Comparison?
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    /// The playable copy last handed to the kit player.
    @ObservationIgnored private var voiceSet: PadVoiceSet?

    init(index: Int) {
        self.index = index
        note = DrumKit.defaultNotes[index]
    }

    var hasSynth: Bool { synth != nil }
    var original: MonoAudio? { analysis?.hit }
    var isEmpty: Bool { synth == nil && !stage.busy }

    /// What the pad shows.
    var name: String { customName ?? originalName }

    /// The name the pad had before any Rename.
    var originalName: String {
        paramsName ?? url?.deletingPathExtension().lastPathComponent ?? ""
    }

    /// An empty name, or the original one, goes back to the original.
    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        customName = trimmed.isEmpty || trimmed == originalName ? nil : trimmed
    }

    // MARK: - Loading

    func open(_ url: URL) {
        if url.pathExtension.lowercased() == DrumParams.fileExtension {
            openParams(url)
        } else {
            load(url)
        }
    }

    func load(_ url: URL) {
        generation += 1
        let mine = generation
        task?.cancel()
        limitPending = false
        self.url = url
        sourceInfo = nil
        source = nil
        analysis = nil
        comparison = nil
        fitted = nil
        score = nil
        paramsName = nil
        customName = nil
        if app?.selected == index { app?.player.setOriginal(nil) }
        stage = .decoding
        let choice = modelChoice
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (audio, info) = try Decoder.decode(url)
                await self?.advance(.analysing, generation: mine)
                let analysis = try Analyzer.analyze(audio, model: choice)
                let comparison = Comparison(target: analysis.hit, pitchTrack: analysis.pitchTrack)
                await self?.analysed(analysis, comparison, audio, info, generation: mine)
            } catch is CancellationError {
                return
            } catch {
                await self?.failed(error.localizedDescription, generation: mine)
            }
        }
    }

    private func advance(_ stage: Stage, generation: Int) {
        guard generation == self.generation else { return }
        self.stage = stage
    }

    private func analysed(_ analysis: Analysis, _ comparison: Comparison, _ audio: MonoAudio, _ info: SourceInfo?,
                          generation: Int) {
        guard generation == self.generation else { return }
        self.analysis = analysis
        self.comparison = comparison
        source = audio
        if let info { sourceInfo = info }
        fitted = nil
        params = analysis.initial
        renderSynth()
        if app?.selected == index { app?.player.setOriginal(analysis.hit) }
        startFit(from: analysis.initial, generation: generation)
    }

    private func failed(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        limitPending = false
        stage = .failed(message)
        app?.message = "Pad \(index + 1): \(message)"
    }

    // MARK: - Model

    /// The model the sample suggests; nil without a sample.
    var suggestedModel: DrumModel? { analysis?.suggested }

    /// The model the panel shows: the drum's, or on an empty pad the one
    /// chosen for it (nil: Automatic).
    var shownModel: DrumModel? { hasSynth ? params.model : modelChoice }

    /// Sets the pad's model, nil for Automatic. On an empty pad that is
    /// all: the next sample is analysed as it. With a sample, analysed
    /// again as that model (or as the one it suggests) and fitted; on a
    /// drum from a file or a kit, the parameters as they are, with the
    /// model's own at their defaults.
    func choose(_ model: DrumModel?) {
        modelChoice = model
        guard hasSynth else { return }
        setModel(model ?? suggestedModel ?? params.model)
    }

    private func setModel(_ model: DrumModel) {
        guard model != params.model else { return }
        guard let source else {
            params.model = model
            return
        }
        generation += 1
        let mine = generation
        task?.cancel()
        paramsName = nil
        stage = .analysing
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let analysis = try Analyzer.analyze(source, model: model)
                let comparison = Comparison(target: analysis.hit, pitchTrack: analysis.pitchTrack)
                await self?.analysed(analysis, comparison, source, nil, generation: mine)
            } catch is CancellationError {
                return
            } catch {
                await self?.failed(error.localizedDescription, generation: mine)
            }
        }
    }

    /// Empty again: no sample, no drum. Pan and note stay - they
    /// belong to the pad's place in the kit, not to the drum on it.
    func clear() {
        generation += 1
        task?.cancel()
        limitPending = false
        url = nil
        sourceInfo = nil
        source = nil
        analysis = nil
        comparison = nil
        fitted = nil
        score = nil
        paramsName = nil
        customName = nil
        synth = nil
        params = DrumParams()
        synth = nil
        stage = .empty
        app?.padChanged(self)
        scheduleVoices()
    }

    // MARK: - Fitting

    private func startFit(from start: DrumParams, generation: Int) {
        guard let analysis, let app else { return }
        stage = .queued
        app.enqueueFit { [weak self] in
            guard let self, generation == self.generation else { return }
            self.stage = .fitting(0)
            do {
                weak let pad = self
                let report = try await Self.runFit(analysis, from: start) { fraction in
                    Task { @MainActor in pad?.advance(.fitting(fraction), generation: generation) }
                }
                self.fitFinished(report, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self.failed(error.localizedDescription, generation: generation)
            }
        }
    }

    /// Off the main thread.
    nonisolated private static func runFit(_ analysis: Analysis, from start: DrumParams,
                                           progress: @escaping @Sendable (Double) -> Void) async throws -> FitReport {
        try await Task.detached(priority: .userInitiated) {
            try Fitter.fit(analysis, from: start, progress: progress)
        }.value
    }

    private func fitFinished(_ report: FitReport, generation: Int) {
        guard generation == self.generation else { return }
        fitted = report
        params = report.params
        renderSynth()
        stage = .done
        if limitPending {
            limitPending = false
            app?.limit(self)
        }
    }

    var canFit: Bool { analysis != nil && !stage.busy }

    /// Fits again, from the parameters as they stand now.
    func refit() {
        guard canFit else { return }
        generation += 1
        startFit(from: params, generation: generation)
    }

    func resetToFit() {
        guard let fitted else { return }
        params = fitted.params
    }

    var canReset: Bool { fitted != nil && fitted?.params != params }

    // MARK: - Rendering

    private func renderSynth() {
        let audio = DrumSynth.renderAudio(params, sampleRate: MonoAudio.analysisRate)
        synth = audio
        score = comparison?.score(params)
        app?.padChanged(self)
        scheduleVoices()
    }

    /// The playable copy, 100 ms after the last change, off the main thread.
    private func scheduleVoices() {
        voiceTask?.cancel()
        guard hasSynth else {
            voiceSet = nil
            app?.kit.setPad(index, nil)
            return
        }
        let params = self.params, pan = self.pan, index = self.index
        voiceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let set = await Task.detached(priority: .userInitiated) {
                PadVoiceSet.make(params: params, pan: pan)
            }.value
            guard !Task.isCancelled else { return }
            self?.voiceSet = set
            self?.app?.kit.setPad(index, set)
        }
    }

    /// Now at place `newIndex` (a swap, AppModel.swapPads). The kit player
    /// gets the playable copy there at once - a click right after the drop
    /// plays this drum, not the one that left - and a copy still being
    /// built, which was headed for the old place, is built again.
    func moved(to newIndex: Int) {
        index = newIndex
        app?.kit.setPad(newIndex, hasSynth ? voiceSet : nil)
        scheduleVoices()
    }

    /// The synth's peak in dBFS, before export.
    var peakDB: Double? {
        guard let synth, synth.frameCount > 0 else { return nil }
        return 20 * log10(max(Double(synth.peak), 1e-9))
    }

    // MARK: - Files

    func openParams(_ url: URL) {
        do {
            let loaded = try DrumParams.read(from: url)
            // Onto the loaded sample, if there is one: the file's sound is
            // then scored against it. Without one, the synth stands alone.
            if analysis == nil {
                generation += 1
                task?.cancel()
                stage = .done
                self.url = nil
                source = nil
            }
            params = loaded
            paramsName = url.deletingPathExtension().lastPathComponent
            customName = nil
            renderSynth()
            app?.message = "Opened \(url.lastPathComponent) on pad \(index + 1)"
        } catch {
            app?.message = "\(url.lastPathComponent) is not a drum parameter file."
        }
    }

    /// From a kit: parameters without a sample, or empty.
    func apply(_ setup: PadSetup) {
        generation += 1
        task?.cancel()
        limitPending = false
        url = nil
        sourceInfo = nil
        source = nil
        analysis = nil
        comparison = nil
        fitted = nil
        score = nil
        pan = setup.pan
        note = setup.note
        modelChoice = setup.model
        customName = nil
        if let loaded = setup.params {
            paramsName = setup.name.isEmpty ? "Pad \(index + 1)" : setup.name
            stage = .done
            params = loaded
            renderSynth()
        } else {
            paramsName = nil
            params = DrumParams()
            synth = nil
            stage = .empty
            app?.padChanged(self)
            scheduleVoices()
        }
    }

    var setup: PadSetup {
        var s = PadSetup(note: note)
        s.name = name
        s.params = hasSynth ? params : nil
        s.pan = pan
        s.model = modelChoice
        return s
    }

    /// The rate the export is rendered at: the source file's own.
    var exportRate: Double { BatchConvert.exportRate(sourceInfo) }

    var baseName: String { name.isEmpty ? "Drum" : name }
}
