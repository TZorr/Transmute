//
//  OneShotPlayer.swift
//  Transmute
//
//  Original or Synth, from the top, as often as the key is pressed.
//
//  DropMaster's A/B player plays two versions of a song under one playhead
//  and crossfades between them. A drum hit is the wrong shape for that: it
//  is over in half a second, and the comparison that matters is between two
//  whole hits heard one after the other - so every trigger starts its
//  source from the first sample, and a trigger during playback restarts it.
//
//  There is no fade-in: a fade over the first milliseconds would soften
//  exactly the attack being judged, and both sources begin at a zero
//  crossing anyway (the Analyzer trims the original to one; the synth's
//  sine starts from its measured phase under a rising envelope). A restart
//  while one is still sounding fades the old one out over 3 ms first, so
//  the cut does not click.
//
//  The pattern - an AVAudioSourceNode whose render block reads atomics and
//  unmanaged pointers - is DropMaster's. Both sources live at the analysis
//  rate; the mixer converts to whatever the output device runs at.
//

import Foundation
import Observation
@preconcurrency import AVFoundation
import Synchronization

nonisolated enum OneShotSource: Int, Sendable {
    case original = 0
    case synth = 1
}

/// Everything the render block touches.
nonisolated final class OneShotCore: @unchecked Sendable {
    let original = Atomic<UnsafeRawPointer?>(nil)
    let synth = Atomic<UnsafeRawPointer?>(nil)
    /// The source asked for by the last trigger, or −1 when none is waiting.
    let pending = Atomic<Int>(-1)
    /// The source sounding, and where in it. −1: silent.
    let playing = Atomic<Int>(-1)
    let position = Atomic<Int>(0)

    // Audio thread only.
    private var current = -1
    private var frame = 0
    /// Frames of fade-out left before a pending hit may start; counted in
    /// whole frames, because a Float step of 1/144 summed 144 times is not
    /// exactly 1 and the fade ran one frame long.
    private var fadeLeft = 0
    private let fadeFrames: Int

    init(sampleRate: Double) {
        fadeFrames = max(Int(0.003 * sampleRate), 1)
    }

    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        { [self] isSilence, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let count = Int(frameCount)
            guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            render(into: out, count: count)
            for extra in buffers.dropFirst() {
                extra.mData?.assumingMemoryBound(to: Float.self).update(from: out, count: count)
            }
            if current < 0 { isSilence.pointee = true }
            return noErr
        }
    }

    /// One block, written over `out`. Separate from the render block so the
    /// harness can drive it without an audio device.
    func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        out.update(repeating: 0, count: count)
        var i = 0
        while i < count {
            let request = pending.load(ordering: .acquiring)
            if request >= 0 {
                if current >= 0 {
                    // Fade the old hit out before the new one starts.
                    if fadeLeft == 0 { fadeLeft = fadeFrames }
                    if let audio = pointer(current) {
                        audio._withUnsafeGuaranteedRef { a in
                            while i < count && fadeLeft > 0 {
                                fadeLeft -= 1
                                if frame < a.frameCount {
                                    out[i] = a.samples[frame] * Float(fadeLeft) / Float(fadeFrames)
                                }
                                frame += 1
                                i += 1
                            }
                        }
                    } else {
                        fadeLeft = 0
                    }
                    if fadeLeft > 0 { break }
                }
                pending.store(-1, ordering: .releasing)
                current = pointer(request) == nil ? -1 : request
                frame = 0
                continue
            }
            guard current >= 0, let audio = pointer(current) else {
                current = -1
                break
            }
            audio._withUnsafeGuaranteedRef { a in
                let n = min(count - i, a.frameCount - frame)
                if n > 0 {
                    (out + i).update(from: a.samples + frame, count: n)
                    frame += n
                    i += n
                }
                if frame >= a.frameCount { current = -1 }
            }
            if current < 0 { break }
        }
        playing.store(current, ordering: .releasing)
        position.store(frame, ordering: .releasing)
    }

    private func pointer(_ source: Int) -> Unmanaged<MonoAudio>? {
        let raw = source == OneShotSource.original.rawValue
            ? original.load(ordering: .acquiring)
            : synth.load(ordering: .acquiring)
        return raw.map { Unmanaged<MonoAudio>.fromOpaque($0) }
    }
}

@Observable
final class OneShotPlayer {
    private let engine = AVAudioEngine()
    let core: OneShotCore
    /// The audio handed to the render block, and the audio before it: the
    /// callback may still be finishing a block of the previous one when a
    /// new one is set, so that one is released one change later.
    @ObservationIgnored private var heldOriginal: [MonoAudio] = []
    @ObservationIgnored private var heldSynth: [MonoAudio] = []
    @ObservationIgnored private var started = false

    /// The source the last trigger played - what Space plays again.
    private(set) var last: OneShotSource = .original

    init(sampleRate: Double = MonoAudio.analysisRate) {
        core = OneShotCore(sampleRate: sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let node = AVAudioSourceNode(format: format, renderBlock: core.makeRenderBlock())
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    var playing: OneShotSource? { OneShotSource(rawValue: core.playing.load(ordering: .acquiring)) }
    /// Seconds into the sounding hit.
    var positionSeconds: Double { Double(core.position.load(ordering: .acquiring)) / MonoAudio.analysisRate }

    func setOriginal(_ audio: MonoAudio?) {
        core.original.store(Self.pointer(audio), ordering: .releasing)
        heldOriginal = Array(heldOriginal.suffix(1)) + (audio.map { [$0] } ?? [])
    }

    func setSynth(_ audio: MonoAudio?) {
        core.synth.store(Self.pointer(audio), ordering: .releasing)
        heldSynth = Array(heldSynth.suffix(1)) + (audio.map { [$0] } ?? [])
    }

    func play(_ source: OneShotSource) {
        if !started { started = (try? engine.start()) != nil }
        last = source
        core.pending.store(source.rawValue, ordering: .releasing)
    }

    func replay() { play(last) }

    private static func pointer(_ audio: MonoAudio?) -> UnsafeRawPointer? {
        audio.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
    }
}
