//
//  DrumKit.swift
//  Transmute
//
//  Sixteen pads, as a `.drumkit` file: for each, its drum's parameters (with
//  the filter and the master envelope), its pan and the MIDI note it
//  answers to. Kits from before 2026-09-26 also hold four velocity slots
//  per pad (`mods`); they are read past and dropped.
//
//  A kit is a synth kit. It holds no samples - not the originals, not
//  renders - only what is needed to play the eight drums again, so a pad
//  loaded from a kit has no original to compare with and no Match figure.
//  A sample can be dropped on it again to analyse and fit.
//
//  Always sixteen pads (eight until 2026-09-26): a file with fewer gets
//  empty pads to fill up - an eight-pad kit opens with 9-16 empty - one
//  with more is cut to sixteen, and a key missing from a pad keeps its
//  default - so a kit saved by an older version still opens.
//
//  Dropped files find their pads by `dropTargets` (the author's spec, 2026-09-26):
//  pad 1 is the multi pad - files dropped there, sorted by name the way
//  Finder sorts them ("Kit 2" before "Kit 10"), go to pads 1-16 without
//  asking, and any beyond sixteen are dropped. Every other pad takes one
//  file, the first by name. Sorted, so a kit exported as "… 1" … "… 16"
//  comes back on its own pads.
//

import Foundation

nonisolated struct PadSetup: Codable, Equatable, Sendable {
    /// What the pad shows; the sample's or the parameter file's name.
    var name: String = ""
    /// The drum, or nil for an empty pad.
    var params: DrumParams?
    /// −100 (left) … +100 (right); playback only, exports stay mono.
    var pan: Double = 0
    /// The MIDI note that plays it, any channel; nil when another pad has
    /// taken it by Learn.
    var note: UInt8?
    /// The model a sample dropped on it is analysed as; nil lets the
    /// analysis choose. Kept for the pad's place, like pan and note.
    var model: DrumModel?

    init(note: UInt8?) { self.note = note }

    init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        params = try c.decodeIfPresent(DrumParams.self, forKey: .params)
        pan = min(max(try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0, -100), 100)
        note = try c.decodeIfPresent(UInt8.self, forKey: .note).map { min($0, 127) }
        model = try? c.decodeIfPresent(DrumModel.self, forKey: .model)
    }
}

nonisolated struct DrumKit: Codable, Equatable, Sendable {
    static let fileExtension = "drumkit"
    static let padCount = 16
    /// MPD218 bank A, all sixteen pads: C1 … D#2.
    static let defaultNotes: [UInt8] = (0..<padCount).map { 36 + UInt8($0) }

    var pads: [PadSetup] = DrumKit.defaultNotes.map { PadSetup(note: $0) }

    init() {}

    init(pads: [PadSetup]) {
        self.pads = pads
        normalise()
    }

    init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pads = try c.decodeIfPresent([PadSetup].self, forKey: .pads) ?? []
        normalise()
    }

    private mutating func normalise() {
        pads = Array(pads.prefix(Self.padCount))
        while pads.count < Self.padCount { pads.append(PadSetup(note: Self.defaultNotes[pads.count])) }
    }

    /// Where dropped files go: on pad 0, the first sixteen by name onto
    /// pads 0-15; on any other, only the first by name, onto it.
    static func dropTargets(_ urls: [URL], on index: Int) -> [(pad: Int, url: URL)] {
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        guard (0..<padCount).contains(index) else { return [] }
        if index == 0 {
            return sorted.prefix(padCount).enumerated().map { ($0.offset, $0.element) }
        }
        return sorted.first.map { [(index, $0)] } ?? []
    }

    /// Points `pad` at `note` and takes the note away from any other pad:
    /// one key playing two pads would be a surprise found mid-groove, and
    /// learning is how one says which (Ultramix's rule for knobs).
    mutating func learn(note: UInt8, for pad: Int) {
        guard pads.indices.contains(pad) else { return }
        for index in pads.indices where index != pad && pads[index].note == note { pads[index].note = nil }
        pads[pad].note = note
    }

    /// The pads a note plays - one, after Learn.
    func pads(for note: UInt8) -> [Int] {
        pads.indices.filter { pads[$0].note == note }
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> DrumKit {
        try JSONDecoder().decode(DrumKit.self, from: Data(contentsOf: url))
    }
}

nonisolated enum NoteName {
    /// "C1" for 36 - the convention Logic and most controllers use.
    static func string(_ note: UInt8?) -> String {
        guard let note else { return "–" }
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 2)"
    }
}
