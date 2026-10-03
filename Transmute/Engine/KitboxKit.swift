//
//  KitboxKit.swift
//  Transmute
//
//  The kit as a Kitbox kit - the author's request (2026-10-03): one
//  `.aupreset` that Kitbox (the 16-pad sampler beside this project) opens
//  with Load Kit, or Logic from its settings menu, with every pad's drum on
//  the same pad.
//
//  The file is Kitbox's own (see Kitbox/Source/Engine/AuPreset.h and
//  KitFile.h): a property list naming the plugin - aumu / Ktbx / Tzor,
//  version 0 - with the plugin's state, base64, under "jucePluginState".
//  That state is the .kitbox container: "KTBX", a little-endian format
//  version (1), then a zlib stream of a JUCE ValueTree in JUCE's binary
//  form:
//
//      KITBOX_FILE
//        KITBOX stateVersion=1 selectedPad=0 kitName="…"
//          PARAM id="pad01_level" value=0.0   … every parameter Kitbox has
//        SAMPLES
//          SAMPLE pad=0 file="Kick.wav" data=<the file's bytes>
//
//  Every parameter is written, at Kitbox's defaults where Transmute has
//  nothing to say: a parameter missing from a loaded state keeps the value
//  it had (JUCE's AudioProcessorValueTreeState), so a partial kit would
//  inherit the last kit's knobs. The defaults are Kitbox's
//  makeParameterLayout (PluginProcessor.cpp) and ParameterIds.h, copied -
//  the one place the two projects must agree by hand.
//
//  What a pad carries over: its drum, rendered as Export would write it
//  (mono, at its sample's rate, in the export boxes' format and depth, the
//  file named as the original-name export names it), its pan (−100…100 →
//  −1…1) and its MIDI note (a pad whose note was learnt away gets its
//  default) - pan and note for an empty pad too, as they belong to the
//  pad's place. Level stays 0 dB - the drum's level is in the file - and
//  Decay at Full, so the file plays out as it was rendered.
//

import Foundation

nonisolated enum KitboxKit {
    static let fileExtension = "aupreset"

    /// One pad: its number (0-based), drum (nil: empty), rate, name, pan
    /// and note.
    struct Pad: Sendable {
        var index: Int
        var params: DrumParams?
        var sampleRate: Double
        var name: String
        /// −100 … +100, as Transmute's pan.
        var pan: Double
        var note: UInt8?
    }

    static let padCount = 16
    static let firstNote = 36

    /// Renders every pad with a drum and writes the preset to `url`; the
    /// sample file names, in pad order.
    @discardableResult
    static func export(_ pads: [Pad], name: String, format: OutputFormat, quality: QualityOption,
                       to url: URL) throws -> [String] {
        let drums = pads.filter { $0.params != nil }
        let names = KitExport.fileNames(for: drums.map { ($0.index, $0.name) }, naming: .original,
                                        fileExtension: format.fileExtension)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transmute Kitbox \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var samples: [Sample] = []
        for (pad, fileName) in zip(drums, names) {
            guard let params = pad.params else { continue }
            try Task.checkCancellation()
            let file = scratch.appendingPathComponent(fileName)
            try Exporter.export(DrumSynth.renderAudio(params, sampleRate: pad.sampleRate),
                                format: format, quality: quality, to: file)
            samples.append(Sample(pad: pad.index, fileName: fileName, bytes: try Data(contentsOf: file)))
        }
        let settings = Dictionary(pads.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        let text = preset(state: state(samples: samples, settings: settings, kitName: name), name: name)
        try Data(text.utf8).write(to: url, options: .atomic)
        return names
    }

    // MARK: - The preset

    static let type = fourCC("aumu")
    static let subtype = fourCC("Ktbx")
    static let manufacturer = fourCC("Tzor")

    static func fourCC(_ code: String) -> Int {
        code.utf8.reduce(0) { $0 << 8 | Int($1) }
    }

    /// The property list, keys in the order Logic (and Kitbox) write them.
    static func preset(state: Data, name: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>jucePluginState</key>
          <data>\(state.base64EncodedString())</data>
          <key>manufacturer</key>
          <integer>\(manufacturer)</integer>
          <key>name</key>
          <string>\(xmlEscaped(name))</string>
          <key>subtype</key>
          <integer>\(subtype)</integer>
          <key>type</key>
          <integer>\(type)</integer>
          <key>version</key>
          <integer>0</integer>
        </dict>
        </plist>

        """
    }

    private static func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - The .kitbox container

    struct Sample: Sendable {
        var pad: Int
        var fileName: String
        var bytes: Data
    }

    static let magic = Data("KTBX".utf8)
    static let formatVersion: Int32 = 1

    /// "KTBX", the version, and the zlib-compressed tree.
    static func state(samples: [Sample], settings: [Int: Pad], kitName: String) -> Data {
        var root = ValueTree("KITBOX_FILE")
        root.children.append(parameters(settings: settings, kitName: kitName))
        var stored = ValueTree("SAMPLES")
        for sample in samples.sorted(by: { $0.pad < $1.pad }) {
            stored.children.append(ValueTree("SAMPLE", [("pad", .int(Int32(sample.pad))),
                                                        ("file", .string(sample.fileName)),
                                                        ("data", .binary(sample.bytes))]))
        }
        root.children.append(stored)

        var out = magic
        withUnsafeBytes(of: formatVersion.littleEndian) { out.append(contentsOf: $0) }
        out.append(Zlib.compress(root.encoded()))
        return out
    }

    /// The parameter tree, every parameter at Kitbox's default but the pads'
    /// pan and note (a pad not in `settings`: those at their defaults too).
    static func parameters(settings: [Int: Pad], kitName: String) -> ValueTree {
        var tree = ValueTree("KITBOX", [("stateVersion", .int(1)), ("selectedPad", .int(0)),
                                        ("kitName", .string(kitName))])
        func param(_ id: String, _ value: Double) {
            tree.children.append(ValueTree("PARAM", [("id", .string(id)), ("value", .double(value))]))
        }
        for (id, value) in globalDefaults { param(id, value) }
        for pad in 0..<padCount {
            let prefix = "pad" + (pad + 1 < 10 ? "0" : "") + "\(pad + 1)_"
            let setting = settings[pad]
            for (suffix, value) in padDefaults {
                switch suffix {
                case "pan": param(prefix + suffix, setting.map { min(max($0.pan / 100, -1), 1) } ?? value)
                case "note": param(prefix + suffix, Double(setting?.note.map { Int(min($0, 127)) } ?? firstNote + pad))
                default: param(prefix + suffix, value)
                }
            }
        }
        return tree
    }

    /// Kitbox's global parameters and their defaults (PluginProcessor.cpp,
    /// ParameterIds.h: humanize, master, and the three effect slots'
    /// type, A, B and level - Plate, Tape delay, Phaser).
    static let globalDefaults: [(String, Double)] = [
        ("humanize", 100), ("master", 0),
        ("rev_type", 0), ("rev_a", 0.5), ("rev_b", 0.4), ("rev_level", 0),
        ("dly_type", 1), ("dly_a", 5.0 / 13.0), ("dly_b", 0.37), ("dly_level", 0),
        ("mod_type", 1), ("mod_a", 0.392), ("mod_b", 0.7), ("phs_level", 0),
    ]

    /// A pad's parameters, in KitParams::Pad::all's order, at their
    /// defaults; "note" is 36 + the pad's index.
    static let padDefaults: [(String, Double)] = [
        ("level", 0), ("pan", 0), ("tune", 0), ("fine", 0), ("start", 0), ("velocity", 100),
        ("attack", 0), ("hold", 0), ("decay", 10_000),
        ("ftype", 0), ("cutoff", 20_000), ("reso", 0), ("drive", 0),
        ("fattack", 0), ("fdecay", 200), ("famount", 0),
        ("rev", 0), ("dly", 0), ("phs", 0),
        ("note", 0), ("choke", 0), ("output", 0),
    ]
}

// MARK: - JUCE's binary ValueTree

/// A JUCE ValueTree, written the way ValueTree::writeToStream writes one:
/// the type as a null-terminated UTF-8 string, the property count, each
/// property's name and value (juce::var::writeToStream), the child count
/// and the children. Counts and sizes are JUCE's "compressed ints": a byte
/// holding how many little-endian bytes follow (bit 7 set for negative).
nonisolated struct ValueTree: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case int(Int32)
        case double(Double)
        case string(String)
        case binary(Data)
    }

    var type: String
    var properties: [(name: String, value: Value)]
    var children: [ValueTree] = []

    init(_ type: String, _ properties: [(name: String, value: Value)] = []) {
        self.type = type
        self.properties = properties
    }

    static func == (a: ValueTree, b: ValueTree) -> Bool {
        a.type == b.type && a.children == b.children
            && a.properties.map(\.name) == b.properties.map(\.name)
            && a.properties.map(\.value) == b.properties.map(\.value)
    }

    func property(_ name: String) -> Value? { properties.first { $0.name == name }?.value }

    // juce::var's stream markers (juce_Variant.cpp).
    static let markerInt: UInt8 = 1
    static let markerDouble: UInt8 = 4
    static let markerString: UInt8 = 5
    static let markerBinary: UInt8 = 8

    func encoded() -> Data {
        var out = Data()
        write(to: &out)
        return out
    }

    private func write(to out: inout Data) {
        Self.writeString(type, to: &out)
        Self.writeCompressedInt(properties.count, to: &out)
        for (name, value) in properties {
            Self.writeString(name, to: &out)
            switch value {
            case .int(let v):
                Self.writeCompressedInt(5, to: &out)
                out.append(Self.markerInt)
                withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
            case .double(let v):
                Self.writeCompressedInt(9, to: &out)
                out.append(Self.markerDouble)
                withUnsafeBytes(of: v.bitPattern.littleEndian) { out.append(contentsOf: $0) }
            case .string(let s):
                let bytes = Array(s.utf8)
                Self.writeCompressedInt(bytes.count + 2, to: &out)   // marker, text, null
                out.append(Self.markerString)
                out.append(contentsOf: bytes)
                out.append(0)
            case .binary(let data):
                Self.writeCompressedInt(data.count + 1, to: &out)
                out.append(Self.markerBinary)
                out.append(data)
            }
        }
        Self.writeCompressedInt(children.count, to: &out)
        for child in children { child.write(to: &out) }
    }

    static func writeString(_ s: String, to out: inout Data) {
        out.append(contentsOf: Array(s.utf8))
        out.append(0)
    }

    static func writeCompressedInt(_ value: Int, to out: inout Data) {
        var magnitude = UInt32(value.magnitude)
        var bytes: [UInt8] = []
        while magnitude > 0 {
            bytes.append(UInt8(magnitude & 0xFF))
            magnitude >>= 8
        }
        out.append(UInt8(bytes.count) | (value < 0 ? 0x80 : 0))
        out.append(contentsOf: bytes)
    }

    /// The reverse, for the harness: a tree from `data`, nil if it is not
    /// one (or holds a value kind written above none of).
    static func decode(_ data: Data) -> ValueTree? {
        var reader = Reader(bytes: [UInt8](data))
        let tree = reader.tree()
        return reader.failed ? nil : tree
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0
        var failed = false

        mutating func byte() -> UInt8 {
            guard position < bytes.count else { failed = true; return 0 }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func take(_ count: Int) -> [UInt8] {
            guard count >= 0, position + count <= bytes.count else { failed = true; return [] }
            defer { position += count }
            return Array(bytes[position..<position + count])
        }

        mutating func string() -> String {
            guard let end = bytes[position...].firstIndex(of: 0) else { failed = true; return "" }
            defer { position = end + 1 }
            return String(decoding: bytes[position..<end], as: UTF8.self)
        }

        mutating func compressedInt() -> Int {
            let size = byte()
            var value = 0
            for (i, b) in take(Int(size & 0x7F)).enumerated() { value |= Int(b) << (8 * i) }
            return size & 0x80 != 0 ? -value : value
        }

        mutating func tree() -> ValueTree {
            var tree = ValueTree(string())
            for _ in 0..<max(0, compressedInt()) where !failed {
                let name = string()
                let size = compressedInt()
                let payload = take(size)
                guard let marker = payload.first else { failed = true; break }
                let body = payload.dropFirst()
                let value: Value
                switch marker {
                case ValueTree.markerInt where body.count == 4:
                    value = .int(Int32(littleEndian: body.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
                case ValueTree.markerDouble where body.count == 8:
                    value = .double(Double(bitPattern: UInt64(littleEndian: body.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })))
                case ValueTree.markerString where body.last == 0:
                    value = .string(String(decoding: body.dropLast(), as: UTF8.self))
                case ValueTree.markerBinary:
                    value = .binary(Data(body))
                default:
                    failed = true
                    return tree
                }
                tree.properties.append((name, value))
            }
            for _ in 0..<max(0, compressedInt()) where !failed { tree.children.append(self.tree()) }
            return tree
        }
    }
}

// MARK: - zlib

/// The zlib format (RFC 1950) JUCE's GZIPCompressorOutputStream writes and
/// its decompressor expects: a two-byte header, raw DEFLATE - which is
/// what Foundation's `.zlib` makes, header-less - and the Adler-32 of the
/// uncompressed bytes, big-endian.
nonisolated enum Zlib {
    static func compress(_ data: Data) -> Data {
        // Default compression, no dictionary: 0x78 0x9C.
        var out = Data([0x78, 0x9C])
        out.append((try? (data as NSData).compressed(using: .zlib) as Data) ?? Data())
        withUnsafeBytes(of: adler32(data).bigEndian) { out.append(contentsOf: $0) }
        return out
    }

    /// The reverse, checking header and checksum; nil if either is wrong.
    static func decompress(_ data: Data) -> Data? {
        guard data.count >= 6, data[data.startIndex] == 0x78 else { return nil }
        let body = data.subdata(in: data.startIndex + 2..<data.endIndex - 4)
        guard let inflated = try? (body as NSData).decompressed(using: .zlib) as Data else { return nil }
        let stored = data.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return stored == adler32(inflated) ? inflated : nil
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { raw in
            var i = 0
            let bytes = raw.bindMemory(to: UInt8.self)
            while i < bytes.count {
                // 5552 bytes is the most that cannot overflow before the modulo.
                let end = min(i + 5552, bytes.count)
                while i < end { a += UInt32(bytes[i]); b += a; i += 1 }
                a %= 65_521
                b %= 65_521
            }
        }
        return b << 16 | a
    }
}
