//
//  OutputFormat.swift
//  Transmute
//
//  The rows of the Format box, and everything the writer needs to know once
//  one is chosen.
//
//  Taken from DropMaster (and Audio Converter before it), with the lossy
//  formats left out on purpose. A drum sample is a one-shot, and its first
//  millisecond is the part that matters: AAC puts 2112 frames of encoder
//  priming in front of it and MP3 its own delay, which a sampler plays as
//  silence before the hit unless the file's gapless metadata is honoured -
//  and many samplers do not. Five lossless formats is all a sample needs.
//
//  All five go through the one ExtAudioFile writer (CoreAudioEncoder).
//

import Foundation
import AudioToolbox

nonisolated enum OutputFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
    case wav
    case aiff
    case caf
    case flac
    case m4aALAC

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .wav:     return "WAV / PCM"
        case .aiff:    return "AIFF / PCM"
        case .caf:     return "CAF"
        case .flac:    return "FLAC"
        case .m4aALAC: return "M4A / ALAC"
        }
    }

    var fileExtension: String {
        switch self {
        case .wav:     return "wav"
        case .aiff:    return "aiff"
        case .caf:     return "caf"
        case .flac:    return "flac"
        case .m4aALAC: return "m4a"
        }
    }

    /// How the ExtAudioFile writer should shape its output.
    enum Container {
        case pcm(AudioFileTypeID)          // linear PCM in some wrapper
        case appleLossless                  // ALAC in an M4A
        case flac                           // FLAC in its own container
    }

    var container: Container {
        switch self {
        case .wav:     return .pcm(kAudioFileWAVEType)
        case .aiff:    return .pcm(kAudioFileAIFFType)   // AIFC is substituted for float, see CoreAudioEncoder
        case .caf:     return .pcm(kAudioFileCAFType)
        case .flac:    return .flac
        case .m4aALAC: return .appleLossless
        }
    }

    // MARK: Quality menu

    /// Bit depths. 24-bit is the default for PCM: a synthesised decay has
    /// no noise floor of its own, and at 16 bits its last 40 dB would be
    /// left to the dither.
    var qualityOptions: [QualityOption] {
        switch self {
        case .wav, .aiff, .caf:
            return [
                .bitDepth(16, isFloat: false),
                .bitDepth(24, isFloat: false, isDefault: true),
                .bitDepth(32, isFloat: true),
            ]
        case .m4aALAC, .flac:
            return [
                .bitDepth(16, isFloat: false),
                .bitDepth(24, isFloat: false, isDefault: true),
            ]
        }
    }

    var defaultQuality: QualityOption {
        qualityOptions.first(where: \.isDefault) ?? qualityOptions[0]
    }
}
