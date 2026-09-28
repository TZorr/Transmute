//
//  KitPlayer.swift
//  Transmute
//
//  The sixteen pads, playable: by a click on a pad or a MIDI note, several at
//  once, each at its place in the stereo field.
//
//  Nothing is synthesised on the audio thread. Each pad hands the player a
//  PadVoiceSet made ahead of time: the drum rendered, and the pan as two
//  gains. A hit plays it from its first sample - so a hit is instant,
//  however heavy the drum's render is. Every hit is the same hit, whatever
//  its velocity: the pads are for listening to what will be exported, and
//  the four velocity slots that made soft hits differ went on 2026-09-26
//  (the author's call - the files are what gets used).
//
//  Sixteen voices. A pad hit while it still sounds fades its old voice out
//  over 3 ms first (the one-shot player's rule: a cut clicks); a hit when
//  all sixteen are busy takes the oldest. Pan is equal-power: the centre is
//  −3 dB per side, hard left is left only.
//
//  The pattern - an AVAudioSourceNode whose render block reads atomics and
//  unmanaged pointers - is the one-shot player's. Hits reach the audio
//  thread through one atomic flag per pad, set while a hit waits to start;
//  two hits of one pad inside one audio block play as one.
//

import Foundation
import Observation
@preconcurrency import AVFoundation
import Synchronization

/// One pad, ready to play. Made off the audio thread, immutable after.
nonisolated final class PadVoiceSet: @unchecked Sendable {
    let audio: MonoAudio
    let panLeft: Float
    let panRight: Float

    init(audio: MonoAudio, pan: Double) {
        self.audio = audio
        let angle = (min(max(pan, -100), 100) + 100) / 200 * Double.pi / 2
        panLeft = Float(cos(angle))
        panRight = Float(sin(angle))
    }

    /// Renders `params` at `rate`.
    static func make(params: DrumParams, pan: Double,
                     sampleRate rate: Double = MonoAudio.analysisRate) -> PadVoiceSet {
        PadVoiceSet(audio: DrumSynth.renderAudio(params, sampleRate: rate), pan: pan)
    }
}

/// One pad's two atomics. A class, because `Atomic` cannot be copied and
/// so cannot sit in an array itself.
nonisolated final class PadChannel: @unchecked Sendable {
    let set = Atomic<UnsafeRawPointer?>(nil)
    /// A hit waiting to start.
    let pending = Atomic<Bool>(false)
}

/// Everything the render block touches.
nonisolated final class KitCore: @unchecked Sendable {
    static let voiceCount = 16

    let pads: [PadChannel] = (0..<DrumKit.padCount).map { _ in PadChannel() }
    /// For the pads' lights: a bit per pad that is sounding.
    let sounding = Atomic<Int>(0)

    private struct Voice {
        var pad = -1
        var set: Unmanaged<PadVoiceSet>?
        var frame = 0
        var left: Float = 0
        var right: Float = 0
        /// Frames of fade-out left; 0 = not fading.
        var fadeLeft = 0
        var age = 0
    }

    // Audio thread only.
    private var voices = [Voice](repeating: Voice(), count: KitCore.voiceCount)
    private var clock = 0
    private let fadeFrames: Int

    init(sampleRate: Double) {
        fadeFrames = max(Int(0.003 * sampleRate), 1)
    }

    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        { [self] isSilence, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let count = Int(frameCount)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let active = render(left: left, right: right, count: count)
            if !active { isSilence.pointee = true }
            return noErr
        }
    }

    /// One block, written over `left` / `right`; true if anything sounded.
    /// Separate from the render block so the harness can drive it.
    @discardableResult
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        startPendingHits()
        var mask = 0
        for v in voices.indices where voices[v].pad >= 0 {
            guard let set = voices[v].set else { voices[v].pad = -1; continue }
            set._withUnsafeGuaranteedRef { s in
                let audio = s.audio
                var i = 0
                while i < count {
                    let f = voices[v].frame
                    guard f < audio.frameCount else { voices[v].pad = -1; break }
                    var gain: Float = 1
                    if voices[v].fadeLeft > 0 {
                        voices[v].fadeLeft -= 1
                        gain = Float(voices[v].fadeLeft) / Float(fadeFrames)
                        if voices[v].fadeLeft == 0 { voices[v].pad = -1 }
                    }
                    let sample = audio.samples[f] * gain
                    left[i] += sample * voices[v].left
                    right[i] += sample * voices[v].right
                    voices[v].frame += 1
                    i += 1
                    if voices[v].pad < 0 { break }
                }
            }
            if voices[v].pad >= 0 { mask |= 1 << voices[v].pad } else { voices[v].set = nil }
        }
        sounding.store(mask, ordering: .releasing)
        return mask != 0
    }

    private func startPendingHits() {
        for pad in 0..<DrumKit.padCount {
            guard pads[pad].pending.exchange(false, ordering: .acquiringAndReleasing),
                  let raw = pads[pad].set.load(ordering: .acquiring) else { continue }
            // The pad's sounding voices fade out; the new hit starts clean.
            for v in voices.indices where voices[v].pad == pad && voices[v].fadeLeft == 0 {
                voices[v].fadeLeft = fadeFrames
            }
            clock += 1
            let slot = voices.firstIndex { $0.pad < 0 }
                ?? voices.indices.min { voices[$0].age < voices[$1].age }!
            let set = Unmanaged<PadVoiceSet>.fromOpaque(raw)
            set._withUnsafeGuaranteedRef { s in
                voices[slot] = Voice(pad: pad, set: set, frame: 0,
                                     left: s.panLeft, right: s.panRight, fadeLeft: 0, age: clock)
            }
        }
    }
}

@Observable
final class KitPlayer {
    private let engine = AVAudioEngine()
    let core: KitCore
    /// Every set handed to the render block in the last 12 seconds, per
    /// pad. A voice reads its set by an unretained pointer for as long as
    /// it plays - up to the longest drum, 10 s - and a slider drag replaces
    /// a pad's set many times in that span, so keeping only the previous
    /// one (the one-shot player's rule) would free a set under a voice.
    /// Counted from when a set was replaced, not when it was made.
    @ObservationIgnored private var held: [[(set: PadVoiceSet, replaced: Date?)]] = Array(repeating: [], count: DrumKit.padCount)
    @ObservationIgnored private var started = false

    init(sampleRate: Double = MonoAudio.analysisRate) {
        core = KitCore(sampleRate: sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format, renderBlock: core.makeRenderBlock())
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func setPad(_ pad: Int, _ set: PadVoiceSet?) {
        core.pads[pad].set.store(set.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) }, ordering: .releasing)
        let now = Date()
        let kept = held[pad].compactMap { entry -> (set: PadVoiceSet, replaced: Date?)? in
            let replaced = entry.replaced ?? now
            return now.timeIntervalSince(replaced) < 12 ? (entry.set, replaced) : nil
        }
        held[pad] = kept + (set.map { [($0, nil)] } ?? [])
    }

    /// A hit, from any thread (MIDI arrives off the main thread).
    nonisolated func hit(_ pad: Int) {
        guard (0..<DrumKit.padCount).contains(pad) else { return }
        core.pads[pad].pending.store(true, ordering: .releasing)
    }

    /// Starts the audio engine; on the main thread, before the first hit.
    func start() {
        if !started { started = (try? engine.start()) != nil }
    }

    func isSounding(_ pad: Int) -> Bool { core.sounding.load(ordering: .acquiring) & (1 << pad) != 0 }
}
