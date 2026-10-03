//
//  BatchConvert.swift
//  Transmute
//
//  Many samples in, as many clean synths out, without the pads - the author's spec
//  (2026-09-26): a separate window to drop files on, with a model for all
//  of them. Automatic lets each sample's analysis choose; a model chosen
//  there is used for every sample, as a pad's model choice is for its own:
//  Clap analyses and fits every file as a clap.
//
//  Each file goes the way a dropped sample goes on a pad - decode, analyse,
//  fit from the Analyzer's guess - and then the way Export Kit writes a
//  pad: mono, at the source's own rate, in the export boxes' format and
//  depth. Optionally the peak is first brought down to the max
//  level (LevelLimit).
//
//  Names, as Export Kit's: by default each file keeps its source's name
//  ("808 CLAP.aif" becomes "808 CLAP.wav"; the same name from two folders
//  gets " 2" on the second - the author's call, 2026-10-03). Renamed, it is
//  "<prefix> <number>", the number the file's place in the list, which is
//  sorted by name the way the pads' Multi drop is - so "Clap 1" is always
//  the first clap by name, and converting the same list again replaces the
//  same files.
//
//  A dropped folder brings its audio files, subfolders included.
//

import Foundation
import UniformTypeIdentifiers

nonisolated enum BatchConvert {
    static let defaultPrefix = "Batch"

    struct Result: Sendable {
        var file: URL
        var params: DrumParams
        /// The fit's Match - before any lowering, which the original's
        /// level would count against it.
        var score: MatchScore
        /// The written file's peak, in dBFS.
        var peakDB: Double
        /// How far Level was lowered to meet the max level; 0 if it was not.
        var loweredDB: Double
    }

    /// The rate a drum is exported at: its source file's own, or 48 kHz
    /// for one outside 22.05-192 kHz or with no file behind it.
    static func exportRate(_ info: SourceInfo?) -> Double {
        guard let rate = info?.sampleRate, (22_050...192_000).contains(rate) else { return 48_000 }
        return rate
    }

    /// The audio files among `urls`, a folder standing for every audio file
    /// in it (subfolders too, hidden ones not), each file once, sorted by
    /// name as the Finder sorts ("2" before "10").
    static func audioFiles(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = walk?.nextObject() as? URL {
                    if isAudio(file) { found.append(file) }
                }
            } else if isAudio(url) {
                found.append(url)
            }
        }
        var seen = Set<String>()
        return sorted(found.filter { seen.insert($0.standardizedFileURL.path).inserted })
    }

    /// By file name, as the Finder sorts; the same name in two folders by
    /// path.
    static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted {
            let byName = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    static func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
    }

    /// "<prefix> <position + 1>.<extension>" - Export Kit's names.
    static func fileName(prefix: String, position: Int, fileExtension: String) -> String {
        KitExport.fileName(prefix: prefix, index: position, fileExtension: fileExtension)
    }

    /// The name each of `sources` is written as: its own (`.original`) or
    /// "<prefix> <position + 1>" - Export Kit's rules, the list's place for
    /// the pad's number.
    static func fileNames(for sources: [URL], naming: KitExport.Naming, fileExtension: String) -> [String] {
        KitExport.fileNames(for: sources.enumerated().map { ($0.offset, $0.element.deletingPathExtension().lastPathComponent) },
                            naming: naming, fileExtension: fileExtension)
    }

    /// Converts `source` into `destination`: decode, analyse (as `model`, or
    /// as the sample suggests), fit, lower to `maxLevelDB` if given, write.
    /// Throws CancellationError when its task is cancelled mid-fit.
    static func convert(_ source: URL, model: DrumModel?, maxLevelDB: Double?,
                        format: OutputFormat, quality: QualityOption, to destination: URL,
                        progress: @escaping (Double) -> Void = { _ in }) throws -> Result {
        let (audio, info) = try Decoder.decode(source)
        try Task.checkCancellation()
        let analysis = try Analyzer.analyze(audio, model: model)
        let report = try Fitter.fit(analysis, progress: progress)
        try Task.checkCancellation()
        let rate = exportRate(info)
        var params = report.params
        var lowered = 0.0
        if let maxLevelDB, let limited = LevelLimit.limited(params, maxDB: maxLevelDB, rates: [rate]) {
            lowered = params.gainDB - limited.gainDB
            params = limited
        }
        let out = DrumSynth.renderAudio(params, sampleRate: rate)
        try Exporter.export(out, format: format, quality: quality, to: destination)
        return Result(file: destination, params: params, score: report.score,
                      peakDB: 20 * log10(max(Double(out.peak), 1e-9)), loweredDB: lowered)
    }
}
