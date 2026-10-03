//
//  KitExport.swift
//  Transmute
//
//  The whole kit as files: one per pad that holds a drum. By default each
//  keeps its pad's own name - the sample's, or the parameter file's - the
//  author's call (2026-10-03): "BD Acoustic Round Indie 01" comes out as
//  "BD Acoustic Round Indie 01.wav". Two pads with one name get " 2", " 3"
//  after the second and third, so neither file replaces the other.
//
//  Renaming is the option (the author's spec, 2026-09-26): a prefix and
//  the pad's number - prefix "TR-707 Transmute" makes "TR-707 Transmute 1"
//  … "TR-707 Transmute 8". The number is the pad's, not a count: a kit
//  with pad 3 empty exports 1, 2, 4 …, so a file always says which pad it
//  came from and a second export of the same kit replaces the same files.
//
//  Each file is what Export makes of its pad on its own: mono, at the rate
//  its sample came in, in the chosen format and depth. Pan is for playing,
//  not for the files.
//
//  The prefix is cleaned for the file system: "/" and ":" (Finder shows a
//  colon as a slash) become "-", runs of spaces one, and an empty prefix
//  is "Kit". An original name loses only "/", ":" and leading dots; a pad
//  without one is "Pad <number>".
//

import Foundation

nonisolated enum KitExport {
    /// One pad to export: its number (0-based index), drum, rate and name.
    struct Item: Sendable {
        var index: Int
        var params: DrumParams
        var sampleRate: Double
        /// The pad's own name, without extension; "" for none.
        var name: String = ""
    }

    /// How the files are named: after the pads (the default), or renamed
    /// "<prefix> <pad number>".
    enum Naming: Sendable, Equatable {
        case original
        case numbered(prefix: String)
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

    /// An original name as it goes into a file name: "/" and ":" become
    /// "-", leading dots go (they would hide the file); the rest stays.
    static func cleanName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        return s
    }

    /// `names` with the second and later of each repeated one numbered -
    /// "Kick", "Kick" → "Kick", "Kick 2" - ignoring case, as the file system
    /// does, and never onto a name already in the list.
    static func uniqued(_ names: [String]) -> [String] {
        var taken = Set(names.map { $0.lowercased() })
        var seen = Set<String>()
        return names.map { name in
            if seen.insert(name.lowercased()).inserted { return name }
            var n = 2
            while taken.contains("\(name) \(n)".lowercased()) { n += 1 }
            let numbered = "\(name) \(n)"
            taken.insert(numbered.lowercased())
            seen.insert(numbered.lowercased())
            return numbered
        }
    }

    /// The file name of every item, in their order.
    static func fileNames(for items: [Item], naming: Naming, fileExtension: String) -> [String] {
        fileNames(for: items.map { ($0.index, $0.name) }, naming: naming, fileExtension: fileExtension)
    }

    /// The same for numbers (0-based) and names alone - Batch Convert's
    /// files, numbered by their place in the list.
    static func fileNames(for entries: [(index: Int, name: String)], naming: Naming, fileExtension: String) -> [String] {
        switch naming {
        case .numbered(let prefix):
            return entries.map { fileName(prefix: prefix, index: $0.index, fileExtension: fileExtension) }
        case .original:
            let names = entries.map { entry in
                let name = cleanName(entry.name)
                return name.isEmpty ? "Pad \(entry.index + 1)" : name
            }
            return uniqued(names).map { "\($0).\(fileExtension)" }
        }
    }

    /// Where each item would be written in `folder`.
    static func urls(for items: [Item], naming: Naming, format: OutputFormat, in folder: URL) -> [URL] {
        fileNames(for: items, naming: naming, fileExtension: format.fileExtension).map { folder.appendingPathComponent($0) }
    }

    /// Renders and writes every item; the files written, in pad order.
    /// Stops at the first failure, which is thrown - the files before it
    /// stay.
    static func export(_ items: [Item], naming: Naming, format: OutputFormat, quality: QualityOption,
                       to folder: URL) throws -> [URL] {
        var written: [URL] = []
        for (item, url) in zip(items, urls(for: items, naming: naming, format: format, in: folder)) {
            let audio = DrumSynth.renderAudio(item.params, sampleRate: item.sampleRate)
            try Exporter.export(audio, format: format, quality: quality, to: url)
            written.append(url)
        }
        return written
    }
}
