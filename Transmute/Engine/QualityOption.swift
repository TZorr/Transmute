//
//  QualityOption.swift
//  Transmute
//
//  One entry in the Quality box: a bit depth, integer or float.
//
//  In DropMaster the same type also carried bitrates for the lossy codecs;
//  Transmute writes lossless formats only (see OutputFormat), so bit depth
//  is the one axis left. The shape - a `Kind` plus a derived `label` - is
//  kept, so the box and the status line cannot drift apart.
//

import Foundation

nonisolated struct QualityOption: Identifiable, Hashable, Sendable {

    enum Kind: Hashable, Sendable {
        /// Linear PCM / ALAC / FLAC target sample format.
        case bitDepth(bits: Int, isFloat: Bool)
    }

    let kind: Kind
    let label: String
    let isDefault: Bool

    var id: String { label }

    static func bitDepth(_ bits: Int, isFloat: Bool, isDefault: Bool = false) -> QualityOption {
        QualityOption(
            kind: .bitDepth(bits: bits, isFloat: isFloat),
            label: isFloat ? "\(bits)-bit float" : "\(bits)-bit",
            isDefault: isDefault
        )
    }

    /// Target integer bit depth, or nil for float. Drives the dither.
    var integerBitDepth: Int? {
        if case .bitDepth(let bits, let isFloat) = kind, !isFloat { return bits }
        return nil
    }

    var isFloatPCM: Bool {
        if case .bitDepth(_, let isFloat) = kind { return isFloat }
        return false
    }

    var pcmBits: Int? {
        if case .bitDepth(let bits, _) = kind { return bits }
        return nil
    }
}
