//
//  KitExport.swift
//  Transmute
//
//  The whole kit as files: one per pad that holds a drum, named from a
//  prefix and the pad's number - the author's spec (2026-09-26): prefix
//  "TR-707 Transmute" makes "TR-707 Transmute 1" … "TR-707 Transmute 8".
//
//  The number is the pad's, not a count: a kit with pad 3 empty exports
//  1, 2, 4 …, so a file always says which pad it came from and a second
//  export of the same kit replaces the same files.
//
//  Each file is what Export makes of its pad on its own: mono, at the rate
//  its sample came in, in the chosen format and depth. Pan is for playing,
//  not for the files.
//
//  The prefix is cleaned for the file system: "/" and ":" (Finder shows a
//  colon as a slash) become "-", runs of spaces one, and an empty prefix
//  is "Kit".
//

import Foundation

nonisolated enum KitExport {
    /// One pad to export: its number (0-based index), drum and rate.
    struct Item: Sendable {
        var index: Int
        var params: DrumParams
        var sampleRate: Double
    }

    static let defaultPrefix = "Kit"

    /// The prefix as it goes into file names.
    static func cleanPrefix(_ prefix: String) -> String {
        var s = prefix.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        // A leading dot would hide the file.
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? defaultPrefix : s
    }

    /// "<prefix> <pad number>.<extension>".
    static func fileName(prefix: String, index: Int, fileExtension: String) -> String {
        "\(cleanPrefix(prefix)) \(index + 1).\(fileExtension)"
    }

    /// Where each item would be written in `folder`.
    static func urls(for items: [Item], prefix: String, format: OutputFormat, in folder: URL) -> [URL] {
        items.map { folder.appendingPathComponent(fileName(prefix: prefix, index: $0.index, fileExtension: format.fileExtension)) }
    }

    /// Renders and writes every item; the files written, in pad order.
    /// Stops at the first failure, which is thrown - the files before it
    /// stay.
    static func export(_ items: [Item], prefix: String, format: OutputFormat, quality: QualityOption,
                       to folder: URL) throws -> [URL] {
        var written: [URL] = []
        for (item, url) in zip(items, urls(for: items, prefix: prefix, format: format, in: folder)) {
            let audio = DrumSynth.renderAudio(item.params, sampleRate: item.sampleRate)
            try Exporter.export(audio, format: format, quality: quality, to: url)
            written.append(url)
        }
        return written
    }
}
