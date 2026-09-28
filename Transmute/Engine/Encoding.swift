//
//  Encoding.swift
//  Transmute
//
//  What every writer looks like from the exporter's side, and how it fails.
//
//  The protocol the exporter writes through, and the error it throws.
//  Taken from DropMaster, where it let one loop feed both CoreAudioEncoder
//  and MP3Encoder; Transmute has only the first, and keeps the protocol so
//  the exporter does not depend on how a file gets written.
//

import Foundation
import AVFoundation

nonisolated protocol AudioEncoder {
    /// Append one chunk: Float32, non-interleaved, in the format the encoder
    /// was created with.
    func write(_ buffer: AVAudioPCMBuffer) throws
    /// Flush and close. After this the output file is complete on disk.
    func finish() throws
    /// Release resources without any promise about the file. Safe to call
    /// after `finish()`, and called on the error path.
    func cancel()
}

nonisolated enum ConversionError: LocalizedError {
    case bufferAllocationFailed
    case encoderSetupFailed(String)
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed:      return "Out of memory."
        case .encoderSetupFailed(let why): return why
        case .encodeFailed(let why):       return why
        }
    }
}
