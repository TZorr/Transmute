//
//  CoreAudioEncoder.swift
//  Transmute
//
//  The one writer for all five export formats: WAV, AIFF, CAF, FLAC and
//  M4A/ALAC. Taken from DropMaster with the AAC branch removed (Transmute
//  writes lossless formats only - see OutputFormat).
//
//  One `ExtAudioFile` does all of it. The trick that makes a single writer
//  cover linear PCM and two lossless codecs is the split between the *file*
//  data format (what ends up on disk) and the *client* data format (what we
//  hand `ExtAudioFileWrite`). The client format is always Float32
//  non-interleaved; ExtAudioFile runs its own AudioConverter between that
//  and whatever the file needs.
//
//  Building the file ASBD by hand for the compressed formats is fragile, so
//  for those we fill only the fields we know and let
//  `kAudioFormatProperty_FormatInfo` complete the description the way the
//  installed codec wants it.
//
//  Every format keeps the rate it is given: Transmute renders the synth at
//  the source file's own rate, so a 44.1 kHz sample comes back at 44.1.
//

import Foundation
import AVFoundation
import AudioToolbox

nonisolated final class CoreAudioEncoder: AudioEncoder {

    private var ref: ExtAudioFileRef?
    private let destination: URL


    init(destination: URL, format: OutputFormat, quality: QualityOption, sourceFormat: AVAudioFormat) throws {
        self.destination = destination

        let source = sourceFormat.streamDescription.pointee
        let (fileType, fileASBD) = try Self.outputDescription(format: format,
                                                              quality: quality,
                                                              source: source)

        var mutableFileASBD = fileASBD
        var created: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(destination as CFURL,
                                               fileType,
                                               &mutableFileASBD,
                                               nil,
                                               AudioFileFlags.eraseFile.rawValue,
                                               &created)
        guard status == noErr, let file = created else {
            throw ConversionError.encoderSetupFailed("Could not create \(format.menuTitle) file (\(Self.osstatus(status))).")
        }
        self.ref = file

        // Hand the writer exactly what the renderer produces.
        var client = source
        let clientStatus = ExtAudioFileSetProperty(file,
                                                   kExtAudioFileProperty_ClientDataFormat,
                                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                                   &client)
        guard clientStatus == noErr else {
            ExtAudioFileDispose(file)
            throw ConversionError.encoderSetupFailed("Writer rejected the input stream (\(Self.osstatus(clientStatus))).")
        }

    }

    // MARK: AudioEncoder

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let ref else { return }
        let status = ExtAudioFileWrite(ref, buffer.frameLength, buffer.audioBufferList)
        guard status == noErr else {
            throw ConversionError.encodeFailed("Write failed (\(Self.osstatus(status))).")
        }
    }

    func finish() throws {
        guard let ref else { return }
        self.ref = nil
        let status = ExtAudioFileDispose(ref)
        guard status == noErr else {
            throw ConversionError.encodeFailed("Could not finalise the file (\(Self.osstatus(status))).")
        }
    }

    func cancel() {
        if let ref {
            ExtAudioFileDispose(ref)
            self.ref = nil
        }
    }

    // MARK: Output description

    private static func outputDescription(format: OutputFormat,
                                          quality: QualityOption,
                                          source: AudioStreamBasicDescription)
        throws -> (AudioFileTypeID, AudioStreamBasicDescription) {

        let channels = source.mChannelsPerFrame
        let sampleRate = source.mSampleRate

        switch format.container {

        case .pcm(let type):
            let bits = UInt32(quality.pcmBits ?? 24)
            let isFloat = quality.isFloatPCM
            let bigEndian = (type == kAudioFileAIFFType || type == kAudioFileAIFCType)

            var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
            flags |= isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
            if bigEndian { flags |= kAudioFormatFlagIsBigEndian }

            let bytesPerFrame = (bits / 8) * channels
            let asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: flags,
                mBytesPerPacket: bytesPerFrame,
                mFramesPerPacket: 1,
                mBytesPerFrame: bytesPerFrame,
                mChannelsPerFrame: channels,
                mBitsPerChannel: bits,
                mReserved: 0)

            // Plain AIFF has no float encoding; its C variant does.
            let resolvedType = (type == kAudioFileAIFFType && isFloat) ? kAudioFileAIFCType : type
            return (resolvedType, asbd)

        case .appleLossless:
            let sourceFlag: AudioFormatFlags = (quality.pcmBits ?? 16) >= 24
                ? kAppleLosslessFormatFlag_24BitSourceData
                : kAppleLosslessFormatFlag_16BitSourceData
            var asbd = AudioStreamBasicDescription()
            asbd.mFormatID = kAudioFormatAppleLossless
            asbd.mSampleRate = sampleRate
            asbd.mChannelsPerFrame = channels
            asbd.mFramesPerPacket = 4096
            asbd.mFormatFlags = sourceFlag
            try completeWithFormatInfo(&asbd)
            return (kAudioFileM4AType, asbd)

        case .flac:
            // FLAC takes its depth from the same source-data flags as ALAC,
            // not from mBitsPerChannel: with the field alone, both "16-bit"
            // and "24-bit" came out as 24-bit files (afinfo: "from 24-bit
            // source"). The harness checks the stored depth of both
            // lossless codecs.
            var asbd = AudioStreamBasicDescription()
            asbd.mFormatID = kAudioFormatFLAC
            asbd.mSampleRate = sampleRate
            asbd.mChannelsPerFrame = channels
            asbd.mFramesPerPacket = 4096
            asbd.mBitsPerChannel = UInt32(quality.pcmBits ?? 16)
            asbd.mFormatFlags = (quality.pcmBits ?? 16) >= 24
                ? kAppleLosslessFormatFlag_24BitSourceData
                : kAppleLosslessFormatFlag_16BitSourceData
            try completeWithFormatInfo(&asbd)
            return (kAudioFileFLACType, asbd)

        }
    }

    /// Ask the installed codec to fill in the fields we left at zero.
    private static func completeWithFormatInfo(_ asbd: inout AudioStreamBasicDescription) throws {
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw ConversionError.encoderSetupFailed("No encoder available for this format (\(osstatus(status))).")
        }
    }


    private static func osstatus(_ status: OSStatus) -> String {
        let code = UInt32(bitPattern: status)
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
           let text = String(bytes: bytes, encoding: .ascii) {
            return "'\(text)'"
        }
        return String(status)
    }

    private func osstatus(_ status: OSStatus) -> String { Self.osstatus(status) }
}
