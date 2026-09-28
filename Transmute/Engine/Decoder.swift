//
//  Decoder.swift
//  Transmute
//
//  Any file macOS can play, in: WAV, AIFF, CAF, FLAC, ALAC, AAC/M4A, MP3.
//  Out: MonoAudio at the analysis rate, plus what the file was before.
//
//  DropMaster's decoder, narrowed to one channel. The two ways in are the
//  same: AVAudioFile plus AVAudioConverter (with the mastering-quality
//  resampler) for nearly every file, and AVAssetReader for the few MP3s the
//  first refuses on the very first read.
//
//  Stereo is folded to mono by averaging, not by the converter's downmix.
//  The downmix has its own ideas about level (−3 dB per side, sometimes
//  more for surround) that would change with the file; an average is the
//  same rule everywhere, and a centred kick keeps exactly its level.
//
//  `SourceInfo.sampleRate` is kept because the export renders at it.
//

import Foundation
// The converter's input block runs synchronously inside `convert`, on this
// thread; AVFAudio's buffers simply predate Sendable annotations.
@preconcurrency import AVFoundation
import Accelerate

/// What the file was before it became MonoAudio.
nonisolated struct SourceInfo: Sendable, Equatable {
    var sampleRate: Double
    var channels: Int
}

nonisolated enum DecodeError: Error, LocalizedError {
    case undecodable(String)
    case tooLong(String)

    var errorDescription: String? {
        switch self {
        case .undecodable(let name): "\(name) is not an audio file Transmute can read."
        case .tooLong(let name): "\(name) is longer than \(Int(Decoder.maxSeconds)) seconds - Transmute models a single hit."
        }
    }
}

nonisolated enum Decoder {
    /// A one-shot, not a loop or a song. Longer files are refused before
    /// decoding everything, not cut: a silently shortened file would be
    /// analysed as if it were the whole sample.
    static let maxSeconds = 10.0

    static func decode(_ url: URL, rate: Double = MonoAudio.analysisRate) throws -> (MonoAudio, SourceInfo) {
        do {
            return try convert(url, rate: rate)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DecodeError {
            if case .tooLong = error { throw error }
            return try readWithAssetReader(url, rate: rate)
        } catch {
            return try readWithAssetReader(url, rate: rate)
        }
    }

    /// Appends the average of `channels` (one buffer each) to `out`.
    private static func fold(_ channels: [UnsafePointer<Float>], count: Int, into out: inout [Float]) {
        let scale = 1 / Float(channels.count)
        let start = out.count
        out.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
        guard channels.count > 1 else { return }
        out.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress! + start
            for channel in channels.dropFirst() {
                vDSP_vadd(base, 1, channel, 1, base, 1, vDSP_Length(count))
            }
            var s = scale
            vDSP_vsmul(base, 1, &s, base, 1, vDSP_Length(count))
        }
    }

    // MARK: - AVAudioFile + AVAudioConverter

    /// In a function of its own: an AVAudioFile finishes its work when it is
    /// released, and Swift releases at the end of a scope, not at last use.
    private static func convert(_ url: URL, rate: Double) throws -> (MonoAudio, SourceInfo) {
        let name = url.lastPathComponent
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw DecodeError.undecodable(name)
        }
        let inFormat = file.processingFormat
        let channels = Int(inFormat.channelCount)
        guard channels > 0 else { throw DecodeError.undecodable(name) }
        if Double(file.length) / inFormat.sampleRate > maxSeconds { throw DecodeError.tooLong(name) }
        // Same channel count out as in: the converter only changes the rate,
        // and the fold below does the channels (see the file header).
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                            channels: inFormat.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw DecodeError.undecodable(name)
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let chunk: AVAudioFrameCount = 32_768
        let ratio = rate / inFormat.sampleRate
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat,
                                               frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 4096) else {
            throw DecodeError.undecodable(name)
        }

        var mono: [Float] = []
        mono.reserveCapacity(Int(Double(max(file.length, 0)) * ratio) + 8192)
        var framesRead: AVAudioFramePosition = 0
        var finished = false
        while true {
            try Task.checkCancellation()
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                // `read` throws at the end of the file rather than returning
                // zero frames, so the throw is the normal way out.
                do {
                    try file.read(into: inBuffer, frameCount: chunk)
                } catch {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                framesRead += AVAudioFramePosition(inBuffer.frameLength)
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error { throw DecodeError.undecodable(name) }
            let count = Int(outBuffer.frameLength)
            if count > 0, let data = outBuffer.floatChannelData {
                fold((0..<channels).map { UnsafePointer(data[$0]) }, count: count, into: &mono)
            }
            if status == .endOfStream || (finished && count == 0) { break }
        }
        // A throw on the very first read is an unreadable file, not an empty
        // one that happens to end at once.
        guard framesRead > 0, !mono.isEmpty else { throw DecodeError.undecodable(name) }
        return (MonoAudio(mono, sampleRate: rate), SourceInfo(sampleRate: inFormat.sampleRate, channels: channels))
    }

    // MARK: - AVAssetReader

    /// The way round for files ExtAudioFile refuses. Asynchronous APIs, run
    /// to completion here: the caller is already off the main thread.
    private static func readWithAssetReader(_ url: URL, rate: Double) throws -> (MonoAudio, SourceInfo) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome = Result<(MonoAudio, SourceInfo), Error>
            .failure(DecodeError.undecodable(url.lastPathComponent))
        Task.detached {
            do {
                outcome = .success(try await read(url, rate: rate))
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try outcome.get()
    }

    private static func read(_ url: URL, rate: Double) async throws -> (MonoAudio, SourceInfo) {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else {
            throw DecodeError.undecodable(name)
        }
        if let duration = try? await asset.load(.duration), duration.seconds > maxSeconds {
            throw DecodeError.tooLong(name)
        }
        var info = SourceInfo(sampleRate: rate, channels: 2)
        if let description = try? await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            info = SourceInfo(sampleRate: basic.mSampleRate, channels: Int(basic.mChannelsPerFrame))
        }
        // Two channels asked for, folded here: the reader's own mono
        // mixdown has the same level question as the converter's.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw DecodeError.undecodable(name) }
        reader.add(output)
        guard reader.startReading() else { throw DecodeError.undecodable(name) }

        var mono: [Float] = []
        var interleaved: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frames = length / (2 * MemoryLayout<Float>.size)
            guard frames > 0 else { continue }
            if interleaved.count < frames * 2 { interleaved = [Float](repeating: 0, count: frames * 2) }
            let copied = interleaved.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 2 * MemoryLayout<Float>.size,
                                           destination: bytes.baseAddress!)
            }
            guard copied == noErr else { throw DecodeError.undecodable(name) }
            for i in 0..<frames {
                mono.append(0.5 * (interleaved[2 * i] + interleaved[2 * i + 1]))
            }
        }
        // Only a complete read counts: a partial one would be analysed as a
        // shorter sample without a word.
        guard reader.status == .completed, !mono.isEmpty else { throw DecodeError.undecodable(name) }
        return (MonoAudio(mono, sampleRate: rate), info)
    }
}
