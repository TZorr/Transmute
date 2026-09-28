//
//  MonoAudio.swift
//  Transmute
//
//  The one shape audio has inside Transmute: one channel of Float32, held in
//  memory, at a rate it carries with it.
//
//  One channel, because the thing being modelled has one: a kick or a tom
//  is a single membrane, and the synth that replaces it is a single voice.
//  A stereo sample is folded to mono on the way in (Decoder); whatever width
//  it had came from the room or the mix, not from the drum.
//
//  The rate travels with the samples instead of being one app-wide constant
//  (DropMaster's StereoAudio fixes 44.1 kHz), because two rates are in play
//  on purpose: analysis always runs at `analysisRate`, so every filter and
//  FFT size is tuned once, while the export is rendered at the source
//  file's own rate - a 44.1 kHz sample should come back at 44.1.
//

import Foundation
import Accelerate

/// Mono Float32 audio at `sampleRate`.
///
/// A class, because it owns its buffer and must free it exactly once, and
/// because the audio thread holds it by an unmanaged pointer. It is written
/// only by whoever creates it and never after it is shared, which is what
/// makes the `@unchecked Sendable` true.
nonisolated final class MonoAudio: @unchecked Sendable {
    /// The rate every analysis runs at.
    static let analysisRate = 48_000.0

    let sampleRate: Double
    let frameCount: Int
    let samples: UnsafeMutablePointer<Float>

    var duration: Double { Double(frameCount) / sampleRate }

    /// Zeroed, for the creator to fill.
    init(frameCount: Int, sampleRate: Double) {
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        // One spare frame, so a zero-length buffer is still a valid pointer.
        samples = .allocate(capacity: max(frameCount, 1))
        samples.initialize(repeating: 0, count: max(frameCount, 1))
    }

    convenience init(_ values: [Float], sampleRate: Double) {
        self.init(frameCount: values.count, sampleRate: sampleRate)
        values.withUnsafeBufferPointer { samples.update(from: $0.baseAddress!, count: $0.count) }
    }

    deinit {
        samples.deallocate()
    }

    var array: [Float] { Array(UnsafeBufferPointer(start: samples, count: frameCount)) }

    /// The largest absolute sample.
    var peak: Float {
        var value: Float = 0
        vDSP_maxmgv(samples, 1, &value, vDSP_Length(frameCount))
        return value
    }
}
