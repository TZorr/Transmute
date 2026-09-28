//
//  Exporter.swift
//  Transmute
//
//  The rendered drum, written as WAV, AIFF, CAF, FLAC or ALAC.
//
//  DropMaster's exporter for one channel instead of two. The audio lives in
//  memory as Float32, so there is no decoder here: the exporter cuts it into
//  chunks, adds dither where the target quantises to integers, and hands the
//  chunks to CoreAudioEncoder.
//
//  Dither is TPDF, one LSB peak each way, for every integer target, on
//  every sample that is not exactly zero (see Dither). A
//  synthesised decay really does fall to nothing, and rounding it to 16
//  bits without dither leaves a buzz that follows the tail down. The
//  generator is deterministic, so the same drum exports to the same bytes.
//  Float targets get none.
//
//  A file that fails half-way is removed, not left behind looking complete.
//

import Foundation
@preconcurrency import AVFoundation

nonisolated enum Exporter {
    static let chunkFrames: AVAudioFrameCount = 32_768

    static func export(_ audio: MonoAudio, format: OutputFormat, quality: QualityOption, to url: URL) throws {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: chunkFrames),
              let channels = buffer.floatChannelData else {
            throw ConversionError.bufferAllocationFailed
        }
        let encoder: AudioEncoder = try CoreAudioEncoder(destination: url, format: format, quality: quality,
                                                         sourceFormat: pcm)
        var dither = Dither(bits: quality.integerBitDepth)
        do {
            var start = 0
            while start < audio.frameCount {
                try Task.checkCancellation()
                let n = min(Int(chunkFrames), audio.frameCount - start)
                channels[0].update(from: audio.samples + start, count: n)
                dither.apply(channels[0], count: n)
                buffer.frameLength = AVAudioFrameCount(n)
                try encoder.write(buffer)
                start += n
            }
            try encoder.finish()
        } catch {
            encoder.cancel()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

/// Triangular dither of ±1 LSB at `bits`, from a deterministic generator.
/// Does nothing when `bits` is nil.
nonisolated struct Dither {
    private let lsb: Float
    private var state: UInt32 = 0x9E37_79B9

    init(bits: Int?) {
        lsb = bits.map { 1 / Float(1 << ($0 - 1)) } ?? 0
    }

    mutating func apply(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard lsb > 0 else { return }
        for i in 0..<count {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let a = Float(state) / 4_294_967_296
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let b = Float(state) / 4_294_967_296
            // Exact silence stays silence: the synth's fade ends on 0, and
            // ±1 LSB of dither would turn that last 0 into the smallest
            // possible step.
            if samples[i] != 0 { samples[i] += (a - b) * lsb }
        }
    }
}
